-- Per-target visual state management.

local M = {}

local targets = {} -- target_name -> state table
local aliases = {} -- ndef_name -> original target_name (e.g. "scvis_block3" -> "block3")
local HISTORY_LEN = 24
local EVENT_HISTORY_LEN = 20
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
    waveform = {},
    amp = 0,
    centroid = 0,
    params = {},
    events = {},
    last_update = 0,
    active = false,
    eval_time = 0,
    has_ndef = false, -- true once wrapped in Ndef and tracked
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
  aliases = {}
end

--- Register an alias: ndef_name -> original target.
--- Once aliased, the block stops receiving _master data and gets per-ndef data instead.
function M.set_alias(ndef_name, original_target)
  aliases[ndef_name] = original_target
  local s = targets[original_target]
  if s then
    s.has_ndef = true
  end
end

--- Resolve a target name through aliases.
local function resolve(target)
  return aliases[target] or target
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
    if #events > EVENT_HISTORY_LEN then
      table.remove(events, 1)
    end
  elseif msg_type == "waveform" then
    local samples = ...
    if samples then s.waveform = samples end
  elseif msg_type == "param" then
    local name, value = ...
    if name then
      s.params[name] = value
    end
  end
end

function M.update(msg_type, target, ...)
  -- "_master" goes to active blocks that DON'T have their own Ndef monitor
  if target == "_master" then
    for _, s in pairs(targets) do
      if s.active and not s.has_ndef then
        apply_update(s, msg_type, ...)
      end
    end
    return
  end

  -- Resolve alias (e.g. "scvis_block3" -> "block3")
  local resolved = resolve(target)
  local s = targets[resolved]
  if not s then return end
  s.active = true
  apply_update(s, msg_type, ...)
end

function M.get_all()
  local t = now()
  for _, s in pairs(targets) do
    -- Prune old events
    local pruned = {}
    for _, ev in ipairs(s.events) do
      if t - ev.time < EVENT_TTL then
        pruned[#pruned + 1] = ev
      end
    end
    s.events = pruned

    -- Decay amplitude when no updates arrive
    if s.active and s.last_update > 0 and (t - s.last_update) > ACTIVE_TTL then
      s.amp = s.amp * DECAY_RATE
      if s.amp < 0.005 then
        s.amp = 0
      end
      local h = s.amp_history
      h[#h + 1] = s.amp
      if #h > HISTORY_LEN then
        table.remove(h, 1)
      end
    end
  end
  return targets
end

return M
