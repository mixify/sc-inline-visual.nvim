-- Pbind pattern preview (one row per recognised key) and recent event timeline.

local braille = require("sc_inline_visual.widgets.braille")
local music = require("sc_inline_visual.music")
local pattern = require("sc_inline_visual.pattern")

local BLOCK_CHARS = braille.BLOCK_CHARS
local amp_hl = braille.amp_hl
local freq_to_note = music.freq_to_note

local M = {}

local HOT_HL = "SCInlineVisualAmpHot"

--- Split a list of pre-formatted cell strings into one segment per cell,
--- separated by `sep`. The cell at `current_idx` (0-based, or -1 to disable)
--- is rendered with `HOT_HL` instead of `base_hl`.
local function highlighted_cells(label, cells, base_hl, sep, current_idx)
  sep = sep or " "
  local segs = { { "  " .. label, "SCInlineVisualDim" } }
  for i, cell in ipairs(cells) do
    segs[#segs + 1] = { cell, (i - 1 == current_idx) and HOT_HL or base_hl }
    if i < #cells then segs[#segs + 1] = { sep, "SCInlineVisualDim" } end
  end
  return segs
end

--- A single Pbind value-list row, dispatched by key name.
--- `p` is the parsed param { key = "freq" | "dur" | ... , values = { ... } }.
--- `current_step` is the live step counter; nil means "no live data yet".
--- The cell at (current_step % #values) is rendered in HOT_HL.
local function render_value_list(p, label, current_step)
  local key = p.key
  local n = #p.values
  local current_idx = (current_step and n > 0) and (current_step % n) or -1

  if key == "dur" then
    -- The dur row is a proportional rhythm bar, not per-cell text; skip step
    -- highlight here. (`current_idx` is meaningless for variable-width cells.)
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
    }
  elseif key == "degree" then
    local cells = {}
    for _, v in ipairs(p.values) do
      cells[#cells + 1] = pattern.degree_to_note(math.floor(v))
    end
    return highlighted_cells(label, cells, "SCInlineVisualHeader", " ", current_idx)
  elseif key == "midinote" or key == "note" then
    local cells = {}
    for _, v in ipairs(p.values) do
      cells[#cells + 1] = music.midi_to_note(math.floor(v))
    end
    return highlighted_cells(label, cells, "SCInlineVisualHeader", " ", current_idx)
  elseif key == "amp" then
    local cells = {}
    for _, v in ipairs(p.values) do
      local idx = math.floor(math.max(0, math.min(1, v)) * 7) + 1
      cells[#cells + 1] = BLOCK_CHARS[idx]
    end
    return highlighted_cells(label, cells, amp_hl(p.values[1] or 0), " ", current_idx)
  elseif key == "freq" then
    local cells = {}
    for _, v in ipairs(p.values) do
      cells[#cells + 1] = freq_to_note(v)
    end
    return highlighted_cells(label, cells, "SCInlineVisualCentroid", " ", current_idx)
  else
    local cells = {}
    for _, v in ipairs(p.values) do
      if v == math.floor(v) then
        cells[#cells + 1] = string.format("%.0f", v)
      else
        cells[#cells + 1] = string.format("%.2g", v)
      end
    end
    return highlighted_cells(label, cells, "SCInlineVisual", " ", current_idx)
  end
end

--- Pbind preview: a header separator + one row per recognised parameter.
--- `current_step` is the live counter from state (incremented by each
--- `/scvis/pat_step` OSC ping). Pass nil to render with no highlight.
--- Empty input returns an empty list (caller appends nothing).
function M.pattern_preview(params, current_step)
  if not params or #params == 0 then return {} end

  local rows = {
    { { "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌", "SCInlineVisualDim" } },
  }
  for _, p in ipairs(params) do
    local label = string.format("%-5s", p.key:sub(1, 4))
    if p.values then
      rows[#rows + 1] = render_value_list(p, label, current_step)
    elseif p.range then
      rows[#rows + 1] = {
        { "  " .. label, "SCInlineVisualDim" },
        { string.format("~%.2g..%.2g", p.range[1], p.range[2]), "SCInlineVisual" },
      }
    end
  end
  return rows
end

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
