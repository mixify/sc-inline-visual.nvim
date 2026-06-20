-- Per-target visual state management.

local M = {}

local targets = {} -- target_name -> state table
local HISTORY_LEN = 24
local EVENT_HISTORY_LEN = 20
local PAT_HISTORY_LEN = 8 -- sliding window of recent Pbind events for the widget
local EVENT_TTL = 3.0 -- seconds
local ACTIVE_TTL = 0.5 -- seconds without data before decay starts
local DECAY_RATE = 0.85

local function now()
  return vim.uv.hrtime() / 1e9
end

local function new_state(block)
  return {
    target = block.target,
    kind = block.kind or "anonymous",
    start_line = block.start_line,
    end_line = block.end_line,
    amp_history = {},
    centroid_history = {},
    amp = 0,
    centroid = 0,
    params = {},
    events = {},
    last_update = 0,
    active = false,
    eval_time = 0,
    monitored = false, -- has its own per-block monitor stream; skip _master broadcast
    pat_history = {}, -- sliding window of recent Pbind events; widget reads its right-end
    last_step_time = 0,
    pat_future = {}, -- forward preview of upcoming events (filled by /scvis/pat_preview)
    pat_future_rev = 0, -- bumped on every preview packet so the renderer can detect refreshes
    cursor_key = nil, -- Pbind key whose value-expr the cursor is on (for row highlight)
  }
end

function M.init(blocks)
  local old = targets
  targets = {}
  for _, block in ipairs(blocks) do
    local prev = old[block.target]
    if prev then
      prev.start_line = block.start_line
      prev.end_line = block.end_line
      prev.kind = block.kind or prev.kind
      targets[block.target] = prev
    else
      targets[block.target] = new_state(block)
    end
  end
end

function M.reset()
  targets = {}
end

--- Mark a target as monitored — either via ~scvisPlayWrap or as an explicit Ndef.
--- Once marked, the block stops receiving _master data and is updated only
--- through its own per-block monitor stream.
function M.mark_wrapped(target)
  local s = targets[target]
  if s then s.monitored = true end
end

--- Reverse of mark_wrapped — called when the SC-side parent has been GC'd,
--- so the block falls back to _master broadcast until it's played again.
function M.unmark_wrapped(target)
  local s = targets[target]
  if s then
    s.monitored = false
    s.last_update = 0
  end
end

--- Record a Pbind event that SC just scheduled, fired by /scvis/pat_event with
--- the resolved key values. Pushes onto the sliding `pat_history` window so the
--- widget can render the last N actually-played notes. Sentinel values from SC
--- (e.g. -1 for missing keys) are stored as-is; the widget renders only the
--- keys the user wrote in their Pbind.
function M.record_event(target, midinote, degree, freq, dur, amp)
  local s = targets[target]
  if not s then return end
  local h = s.pat_history
  h[#h + 1] = {
    midinote = midinote,
    degree = degree,
    freq = freq,
    dur = dur,
    amp = amp,
  }
  if #h > PAT_HISTORY_LEN then table.remove(h, 1) end
  s.last_step_time = now()
  s.active = true
end

--- Record one event of the forward preview that SC pulled offline from an
--- independent stream (fired once per evaluation via /scvis/pat_preview).
--- `index` is 0-based; index 0 starts a fresh batch, so we drop the previous
--- preview window before appending. Sentinels are stored as-is; the widget
--- renders only the keys the user actually wrote in their Pbind.
function M.record_preview(target, index, midinote, degree, freq, dur, amp)
  local s = targets[target]
  if not s then return end
  if index == 0 then s.pat_future = {} end
  s.pat_future[index + 1] = {
    midinote = midinote,
    degree = degree,
    freq = freq,
    dur = dur,
    amp = amp,
  }
  s.pat_future_rev = s.pat_future_rev + 1
end

--- Mark a block as active (user evaluated it).
function M.activate(target)
  local s = targets[target]
  if s then
    s.active = true
    s.eval_time = now()
  end
end

--- Mark a block as active by the line number that was evaluated.
--- Returns the target name and kind if found.
function M.activate_by_line(line_0indexed)
  for _, s in pairs(targets) do
    if line_0indexed >= s.start_line and line_0indexed <= s.end_line then
      s.active = true
      s.eval_time = now()
      return s.target, s.kind
    end
  end
  return nil, nil
end

--- Deactivate all blocks.
function M.deactivate_all()
  for _, s in pairs(targets) do
    s.active = false
  end
end

--- Get the kind of a target.
function M.get_kind(target)
  local s = targets[target]
  return s and s.kind or nil
end

--- Read-only lookup of the block covering a 0-indexed buffer line. Unlike
--- `activate_by_line` this has no side effects — used by the cursor-highlight
--- handler, which must not mark blocks active just because the cursor passes
--- over them. Returns target, start_line, end_line.
function M.target_at_line(line_0indexed)
  for _, s in pairs(targets) do
    if line_0indexed >= s.start_line and line_0indexed <= s.end_line then
      return s.target, s.start_line, s.end_line
    end
  end
  return nil
end

--- Set the Pbind key the cursor is currently on for `target` (nil to clear).
function M.set_cursor_key(target, key)
  local s = targets[target]
  if s then s.cursor_key = key end
end

--- Clear the cursor-on-key highlight for every block.
function M.clear_cursor_keys()
  for _, s in pairs(targets) do
    s.cursor_key = nil
  end
end

local function apply_update(s, msg_type, ...)
  s.last_update = now()

  if msg_type == "analysis" then
    local amp, centroid = ...
    s.amp = amp or 0
    s.centroid = centroid or 0
    local h = s.amp_history
    h[#h + 1] = s.amp
    if #h > HISTORY_LEN then table.remove(h, 1) end
    local ch = s.centroid_history
    ch[#ch + 1] = s.centroid
    if #ch > HISTORY_LEN then table.remove(ch, 1) end
  elseif msg_type == "event" then
    local name, amp = ...
    local events = s.events
    events[#events + 1] = { name = name or "event", amp = amp or 1, time = now() }
    if #events > EVENT_HISTORY_LEN then table.remove(events, 1) end
  elseif msg_type == "param" then
    local name, value = ...
    if name then s.params[name] = value end
  end
end

function M.update(msg_type, target, ...)
  -- "_master" goes to active blocks that don't have their own per-block monitor.
  if target == "_master" then
    for _, s in pairs(targets) do
      if s.active and not s.monitored then apply_update(s, msg_type, ...) end
    end
    return
  end

  -- Per-block stream: SC tags each message with the parent target name directly,
  -- so a straight lookup is enough — no alias resolution needed.
  local s = targets[target]
  if not s then return end
  s.active = true
  apply_update(s, msg_type, ...)
end

function M.get_all()
  local t = now()
  for _, s in pairs(targets) do
    if #s.events > 0 and (t - s.events[1].time) >= EVENT_TTL then
      local pruned = {}
      for _, ev in ipairs(s.events) do
        if t - ev.time < EVENT_TTL then pruned[#pruned + 1] = ev end
      end
      s.events = pruned
    end

    if s.active and s.last_update > 0 and (t - s.last_update) > ACTIVE_TTL then
      if s.amp > 0 then
        s.amp = s.amp * DECAY_RATE
        if s.amp < 0.005 then s.amp = 0 end
        local h = s.amp_history
        h[#h + 1] = s.amp
        if #h > HISTORY_LEN then table.remove(h, 1) end
      end
    end
  end
  return targets
end

return M
