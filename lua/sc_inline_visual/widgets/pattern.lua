-- Pbind pattern preview (one row per recognised key) and recent event timeline.

local braille = require("sc_inline_visual.widgets.braille")
local music = require("sc_inline_visual.music")
local pattern = require("sc_inline_visual.pattern")

local BLOCK_CHARS = braille.BLOCK_CHARS
local amp_hl = braille.amp_hl
local freq_to_note = music.freq_to_note

local M = {}

local HOT_HL = "SCInlineVisualAmpHot"

--- Pack a value list into fixed-width cells so the beat grid below can line
--- up `│··│··` markers under each cell's start. Returns the segment list and
--- the cell width (so pattern_preview can mirror it in the grid row).
---
--- The cell at `current_idx` (0-based, -1 to disable) is rendered in HOT_HL.
local function highlighted_cells(label, cells, base_hl, current_idx)
  local max_w = 1
  for _, c in ipairs(cells) do
    max_w = math.max(max_w, vim.fn.strdisplaywidth(c))
  end
  local cell_w = max_w + 1 -- one trailing space per cell for separation

  local segs = { { "  " .. label, "SCInlineVisualDim" } }
  for i, cell in ipairs(cells) do
    local pad = cell_w - vim.fn.strdisplaywidth(cell)
    local hl = (i - 1 == current_idx) and HOT_HL or base_hl
    segs[#segs + 1] = { cell, hl }
    if pad > 0 then segs[#segs + 1] = { string.rep(" ", pad), "SCInlineVisualDim" } end
  end
  return segs, cell_w
end

--- A single Pbind value-list row, dispatched by key name.
--- `p` is the parsed param { key = "freq" | "dur" | ... , values = { ... } }.
--- `current_step` is the live step counter; nil means "no live data yet".
---
--- Returns `(segments, cell_w, n_cells)`. The dur row is special — it renders
--- as a proportional bar (no discrete cells) and returns nil for cell_w so the
--- caller knows not to use it as the grid reference row.
local function render_value_list(p, label, current_step)
  local key = p.key
  local n = #p.values
  local current_idx = (current_step and n > 0) and (current_step % n) or -1

  if key == "dur" then
    local total = 0
    for _, v in ipairs(p.values) do
      total = total + v
    end
    local WIDTH = 20
    local chars = {}
    for _, v in ipairs(p.values) do
      local w = math.max(1, math.floor(v / total * WIDTH + 0.5))
      if w == 1 then
        chars[#chars + 1] = "▎"
      elseif w == 2 then
        chars[#chars + 1] = "▍▎"
      else
        chars[#chars + 1] = "█" .. string.rep("─", w - 2) .. "▎"
      end
    end
    return {
      { "  " .. label, "SCInlineVisualDim" },
      { table.concat(chars), "SCInlineVisualAmpMid" },
    },
      nil,
      nil
  elseif key == "degree" then
    local cells = {}
    for _, v in ipairs(p.values) do
      cells[#cells + 1] = pattern.degree_to_note(math.floor(v))
    end
    local segs, cw = highlighted_cells(label, cells, "SCInlineVisualHeader", current_idx)
    return segs, cw, #cells
  elseif key == "midinote" or key == "note" then
    local cells = {}
    for _, v in ipairs(p.values) do
      cells[#cells + 1] = music.midi_to_note(math.floor(v))
    end
    local segs, cw = highlighted_cells(label, cells, "SCInlineVisualHeader", current_idx)
    return segs, cw, #cells
  elseif key == "amp" then
    local cells = {}
    for _, v in ipairs(p.values) do
      local idx = math.floor(math.max(0, math.min(1, v)) * 7) + 1
      cells[#cells + 1] = BLOCK_CHARS[idx]
    end
    local segs, cw = highlighted_cells(label, cells, amp_hl(p.values[1] or 0), current_idx)
    return segs, cw, #cells
  elseif key == "freq" then
    local cells = {}
    for _, v in ipairs(p.values) do
      cells[#cells + 1] = freq_to_note(v)
    end
    local segs, cw = highlighted_cells(label, cells, "SCInlineVisualCentroid", current_idx)
    return segs, cw, #cells
  else
    local cells = {}
    for _, v in ipairs(p.values) do
      if v == math.floor(v) then
        cells[#cells + 1] = string.format("%.0f", v)
      else
        cells[#cells + 1] = string.format("%.2g", v)
      end
    end
    local segs, cw = highlighted_cells(label, cells, "SCInlineVisual", current_idx)
    return segs, cw, #cells
  end
end

--- Beat ruler with a snap playhead. `│··` marks each step boundary; the
--- current step (current_step % n_cells) replaces its `│` with `▲`. When
--- `current_step` is nil / negative, the row is rendered with no playhead.
local function beat_grid(current_step, n_cells, cell_w)
  if n_cells <= 0 or cell_w <= 0 then return nil end
  local active_idx = (current_step and current_step >= 0) and (current_step % n_cells) or -1

  local segs = { { "  beat ", "SCInlineVisualDim" } }
  for i = 0, n_cells - 1 do
    local is_active = (i == active_idx)
    segs[#segs + 1] = { is_active and "▲" or "│", is_active and HOT_HL or "SCInlineVisualDim" }
    if cell_w > 1 then segs[#segs + 1] = { string.rep("·", cell_w - 1), "SCInlineVisualDim" } end
  end
  return segs
end

--- Pbind preview: a header separator + one row per recognised parameter,
--- and a beat-grid playhead row at the bottom keyed off the first values-
--- bearing key (whichever has fixed-width cells — dur's proportional bar
--- doesn't qualify). `current_step` is the live counter from state, bumped
--- by each `/scvis/pat_step` OSC ping; pass nil for no playhead.
function M.pattern_preview(params, current_step)
  if not params or #params == 0 then return {} end

  local rows = {
    { { "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌", "SCInlineVisualDim" } },
  }
  local grid_cell_w, grid_n_cells = nil, nil
  for _, p in ipairs(params) do
    local label = string.format("%-5s", p.key:sub(1, 4))
    if p.values then
      local segs, cell_w, n_cells = render_value_list(p, label, current_step)
      rows[#rows + 1] = segs
      -- First fixed-width row sets the grid scale. The dur row reports nil
      -- because its proportional bar doesn't map to discrete cells.
      if not grid_cell_w and cell_w then
        grid_cell_w = cell_w
        grid_n_cells = n_cells
      end
    elseif p.range then
      rows[#rows + 1] = {
        { "  " .. label, "SCInlineVisualDim" },
        { string.format("~%.2g..%.2g", p.range[1], p.range[2]), "SCInlineVisual" },
      }
    end
  end

  local grid = grid_cell_w and beat_grid(current_step, grid_n_cells, grid_cell_w)
  if grid then rows[#rows + 1] = grid end

  return rows
end

-- Internal-only handle for smoke tests.
M._beat_grid = beat_grid

--- Recent-event timeline: drops a glyph at the slot matching each event's age
--- inside a 3-second sliding window. Older events fall off the left.
function M.event_timeline(events)
  local WIDTH = 16
  local WINDOW = 3.0
  local now = vim.uv.hrtime() / 1e9

  local slots = {}
  for i = 1, WIDTH do
    slots[i] = " "
  end

  local glyphs = { kick = "●", snare = "◆", hat = "·", note = "•" }
  for _, ev in ipairs(events) do
    local age = now - ev.time
    if age < WINDOW then
      local pos = math.floor((1 - age / WINDOW) * (WIDTH - 1)) + 1
      slots[math.max(1, math.min(WIDTH, pos))] = glyphs[ev.name] or "●"
    end
  end

  return {
    { "ev   ", "SCInlineVisualDim" },
    { table.concat(slots), "SCInlineVisualEvent" },
  }
end

return M
