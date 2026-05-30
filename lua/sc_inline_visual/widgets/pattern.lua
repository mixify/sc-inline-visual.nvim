-- Pbind pattern preview (one row per recognised key) and recent event timeline.

local braille = require("sc_inline_visual.widgets.braille")
local music = require("sc_inline_visual.music")
local pattern = require("sc_inline_visual.pattern")

local BLOCK_CHARS = braille.BLOCK_CHARS
local amp_hl = braille.amp_hl
local freq_to_note = music.freq_to_note

local M = {}

--- A single Pbind value-list row, dispatched by key name.
--- `p` is the parsed param { key = "freq" | "dur" | ... , values = { ... } }.
--- Returns nil for unknown / unrenderable shapes (caller skips them).
local function render_value_list(p, label)
  local key = p.key
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
    }
  elseif key == "degree" then
    local notes = {}
    for _, v in ipairs(p.values) do
      notes[#notes + 1] = pattern.degree_to_note(math.floor(v))
    end
    return {
      { "  " .. label, "SCInlineVisualDim" },
      { table.concat(notes, " "), "SCInlineVisualHeader" },
    }
  elseif key == "midinote" or key == "note" then
    local notes = {}
    for _, v in ipairs(p.values) do
      notes[#notes + 1] = music.midi_to_note(math.floor(v))
    end
    return {
      { "  " .. label, "SCInlineVisualDim" },
      { table.concat(notes, " "), "SCInlineVisualHeader" },
    }
  elseif key == "amp" then
    local chars = {}
    for _, v in ipairs(p.values) do
      local idx = math.floor(math.max(0, math.min(1, v)) * 7) + 1
      chars[#chars + 1] = BLOCK_CHARS[idx]
    end
    return {
      { "  " .. label, "SCInlineVisualDim" },
      { table.concat(chars, " "), amp_hl(p.values[1] or 0) },
    }
  elseif key == "freq" then
    local notes = {}
    for _, v in ipairs(p.values) do
      notes[#notes + 1] = freq_to_note(v)
    end
    return {
      { "  " .. label, "SCInlineVisualDim" },
      { table.concat(notes, " "), "SCInlineVisualCentroid" },
    }
  else
    local strs = {}
    for _, v in ipairs(p.values) do
      if v == math.floor(v) then
        strs[#strs + 1] = string.format("%.0f", v)
      else
        strs[#strs + 1] = string.format("%.2g", v)
      end
    end
    return {
      { "  " .. label, "SCInlineVisualDim" },
      { table.concat(strs, " "), "SCInlineVisual" },
    }
  end
end

--- Pbind preview: a header separator + one row per recognised parameter.
--- Empty input returns an empty list (caller appends nothing).
function M.pattern_preview(params)
  if not params or #params == 0 then return {} end

  local rows = {
    { { "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌", "SCInlineVisualDim" } },
  }
  for _, p in ipairs(params) do
    local label = string.format("%-5s", p.key:sub(1, 4))
    if p.values then
      rows[#rows + 1] = render_value_list(p, label)
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
