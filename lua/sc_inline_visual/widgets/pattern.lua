-- Pbind pattern preview rendered from the live event history (`pat_history`)
-- that the SC `\callback` hook fills, plus the user-event timeline.
--
-- We deliberately don't render the static value arrays parsed from the user's
-- source — for stochastic patterns (`Pwrand`, `Pbrown`, ...) the static array
-- would say one thing and the audio another. The history shows the values SC
-- actually scheduled, so the widget never lies regardless of pattern type.

local braille = require("sc_inline_visual.widgets.braille")
local music = require("sc_inline_visual.music")
local pattern = require("sc_inline_visual.pattern")

local BLOCK_CHARS = braille.BLOCK_CHARS
local amp_hl_fn = braille.amp_hl
local freq_to_note = music.freq_to_note

local M = {}

local HOT_HL = "SCInlineVisualAmpHot"
local DIM_HL = "SCInlineVisualDim"
local ACTIVE_HL = "SCInlineVisualActive"
local PLACEHOLDER = "·"

--- Label cell for a key row: a `▸` marker + bright label when the cursor is on
--- this key's value-expression, otherwise the usual dim, space-prefixed label.
--- Width is identical in both states so the grid never shifts.
local function label_seg(key, active)
  local label = string.format("%-5s", key:sub(1, 4))
  if active then return { "▸ " .. label, ACTIVE_HL } end
  return { "  " .. label, DIM_HL }
end
local WINDOW = 8 -- match state.PAT_HISTORY_LEN; the row is right-aligned in this many cells.

--- Format a single event-key value to a display cell, honouring the sentinel
--- numbers SC sends when a Pbind key isn't present in the event (so we don't
--- pollute the row with garbage). Returns nil for sentinels so the caller can
--- fall back to the placeholder.
local function format_cell(key, value)
  if not value then return nil end
  if key == "midinote" or key == "note" then
    if value < 0 then return nil end
    return music.midi_to_note(math.floor(value))
  elseif key == "degree" then
    if value < -100 then return nil end -- sentinel -999
    return pattern.degree_to_note(math.floor(value))
  elseif key == "freq" then
    if value < 0 then return nil end
    return freq_to_note(value)
  elseif key == "amp" then
    if value < 0 then return nil end
    local idx = math.floor(math.max(0, math.min(1, value)) * 7) + 1
    return BLOCK_CHARS[idx]
  elseif key == "dur" then
    if value <= 0 then return nil end
    return string.format("%.2g", value)
  else
    return string.format("%.2g", value)
  end
end

local function base_hl_for(key)
  if key == "midinote" or key == "note" or key == "degree" then
    return "SCInlineVisualHeader"
  elseif key == "freq" then
    return "SCInlineVisualCentroid"
  elseif key == "amp" then
    return "SCInlineVisualAmpMid"
  else
    return "SCInlineVisual"
  end
end

--- Right-align `n_actual` value cells in a window of WINDOW cells, padding
--- the left with placeholder dots. The rightmost actual cell is the latest
--- event for this key and is rendered in HOT_HL; placeholders are dim;
--- everything else uses `base_hl`. Returns segments + cell width.
local function render_row(key, history, active)
  local cells = {}
  for _, ev in ipairs(history) do
    cells[#cells + 1] = format_cell(key, ev[key]) or PLACEHOLDER
  end
  -- Right-align: pad the left with placeholders so the most recent event
  -- always sits in the rightmost slot.
  while #cells < WINDOW do
    table.insert(cells, 1, PLACEHOLDER)
  end

  local max_w = 1
  for _, c in ipairs(cells) do
    max_w = math.max(max_w, vim.fn.strdisplaywidth(c))
  end
  local cell_w = max_w + 1

  local current_idx = (#history > 0) and (WINDOW - 1) or -1
  local base = base_hl_for(key)
  local segs = { label_seg(key, active) }
  for i, cell in ipairs(cells) do
    local hl
    if cell == PLACEHOLDER then
      hl = DIM_HL
    elseif i - 1 == current_idx then
      hl = HOT_HL
    else
      hl = base
    end
    segs[#segs + 1] = { cell, hl }
    local pad = cell_w - vim.fn.strdisplaywidth(cell)
    if pad > 0 then segs[#segs + 1] = { string.rep(" ", pad), DIM_HL } end
  end
  return segs
end

--- Pbind preview: header separator + one row per key the user actually wrote,
--- with values pulled from `pat_history` (set by `state.record_event` whenever
--- SC's `\callback` fires). When the history is empty, every row shows a
--- string of dim placeholders to indicate "not playing yet".
function M.pattern_preview(params, pat_history, active_key)
  if not params or #params == 0 then return {} end
  pat_history = pat_history or {}

  local rows = {
    { { "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌", DIM_HL } },
  }
  for _, p in ipairs(params) do
    rows[#rows + 1] = render_row(p.key, pat_history, p.key == active_key)
  end
  return rows
end

local FUT_MAX_COLS = 12

--- Compact onset-time label: "0", ".25", "1.5", stripping the leading zero on
--- sub-beat values so the time axis reads like the user's mental beat grid.
local function fmt_onset(t)
  if t == 0 then return "0" end
  if math.abs(t - math.floor(t + 0.5)) < 1e-6 then return string.format("%d", math.floor(t + 0.5)) end
  local s = string.format("%.3g", t)
  s = s:gsub("^(-?)0%.", "%1.")
  return s
end

--- Forward timeline: preview the next N events SC pulled from an independent
--- stream (`pat_future`), laid out left→right as an evenly-spaced grid with a
--- cumulative-time axis on top and one row per key the user wrote. Unlike
--- `pattern_preview` (which shows the past), this shows what's *about* to play —
--- so you can read the shape of the next bars before hearing them. For
--- stochastic patterns it's representative, not the exact future.
function M.pattern_future(params, pat_future, active_key)
  if not params or #params == 0 then return {} end
  pat_future = pat_future or {}

  if #pat_future == 0 then
    -- Block not evaluated yet → nothing to preview. Show a dim hint so the
    -- row is reserved and the user knows where the timeline will appear.
    return { { { "  ▸ ", DIM_HL }, { "next … (eval to preview)", DIM_HL } } }
  end

  local n = math.min(#pat_future, FUT_MAX_COLS)

  -- Cumulative onset of each event. Missing dur (sentinel ≤ 0) falls back to a
  -- 1-beat step — SC's own default — so the axis still advances sensibly.
  local onsets = {}
  local t = 0
  for i = 1, n do
    onsets[i] = t
    local d = pat_future[i].dur
    t = t + ((type(d) == "number" and d > 0) and d or 1)
  end

  local time_cells = {}
  for i = 1, n do
    time_cells[i] = fmt_onset(onsets[i])
  end

  local key_cells = {}
  for _, p in ipairs(params) do
    local cells = {}
    for i = 1, n do
      cells[i] = format_cell(p.key, pat_future[i][p.key]) or PLACEHOLDER
    end
    key_cells[p.key] = cells
  end

  -- One shared column width keeps every row aligned into a readable grid.
  local cell_w = 1
  for i = 1, n do
    cell_w = math.max(cell_w, vim.fn.strdisplaywidth(time_cells[i]))
    for _, p in ipairs(params) do
      cell_w = math.max(cell_w, vim.fn.strdisplaywidth(key_cells[p.key][i]))
    end
  end
  cell_w = cell_w + 1

  local function grid_row(label, cells, hl, active)
    local segs = { label_seg(label, active) }
    for i = 1, n do
      local cell = cells[i]
      segs[#segs + 1] = { cell, (cell == PLACEHOLDER) and DIM_HL or hl }
      local pad = cell_w - vim.fn.strdisplaywidth(cell)
      if pad > 0 then segs[#segs + 1] = { string.rep(" ", pad), DIM_HL } end
    end
    return segs
  end

  local rows = {
    { { "  ▸ next ", DIM_HL }, { string.rep("╌", math.max(2, n * cell_w - 6)) .. "▶", DIM_HL } },
    grid_row("t", time_cells, "SCInlineVisualDim", false),
  }
  for _, p in ipairs(params) do
    rows[#rows + 1] = grid_row(p.key, key_cells[p.key], base_hl_for(p.key), p.key == active_key)
  end
  return rows
end

--- Recent-event timeline: drops a glyph at the slot matching each event's age
--- inside a 3-second sliding window. Older events fall off the left.
function M.event_timeline(events)
  local WIDTH = 16
  local WINDOW_SEC = 3.0
  local now = vim.uv.hrtime() / 1e9

  local slots = {}
  for i = 1, WIDTH do
    slots[i] = " "
  end

  local glyphs = { kick = "●", snare = "◆", hat = "·", note = "•" }
  for _, ev in ipairs(events) do
    local age = now - ev.time
    if age < WINDOW_SEC then
      local pos = math.floor((1 - age / WINDOW_SEC) * (WIDTH - 1)) + 1
      slots[math.max(1, math.min(WIDTH, pos))] = glyphs[ev.name] or "●"
    end
  end

  return {
    { "ev   ", DIM_HL },
    { table.concat(slots), "SCInlineVisualEvent" },
  }
end

-- Suppress "unused" lint for the amp band helper — kept for future per-cell
-- amplitude colouring in the `\amp` row.
local _ = amp_hl_fn

return M
