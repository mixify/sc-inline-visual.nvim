-- Source-value slider: `name   value   lo ━━━●━━━ hi`. The handle is the literal
-- in the buffer (so it jumps the instant you scrub), positioned inside the
-- control's ControlSpec range with the spec's warp. Endpoints are the spec
-- min/max. Drawn only for controls whose name has a known spec (see specs.lua).

local specs = require("sc_inline_visual.specs")

local M = {}

local TRACK = 12 -- track cells, excluding the handle

-- Compact number: 20000→"20k", 4200→"4.2k", 0.125→"0.125", 440→"440", -20→"-20".
local function fmt(x)
  if x == 0 then return "0" end
  local ax = math.abs(x)
  if ax >= 1000 then return string.format("%gk", x / 1000) end
  return string.format("%g", x)
end

--- Render one slider row for `name` at `value` within `spec` ({min,max,warp}).
--- Returns a list of `{ text, hl_group }` segments.
function M.slider(name, value, spec)
  local pos = specs.unmap(spec, value)
  local idx = math.floor(pos * TRACK + 0.5) -- 0..TRACK handle cell
  return {
    { string.format("%-6s", name:sub(1, 6)), "SCInlineVisualDim" },
    { string.format("%7s  ", fmt(value)), "SCInlineVisual" },
    { fmt(spec[1]) .. " ", "SCInlineVisualDim" },
    { string.rep("━", idx), "SCInlineVisualDim" },
    { "●", "SCInlineVisualActive" },
    { string.rep("━", TRACK - idx), "SCInlineVisualDim" },
    { " " .. fmt(spec[2]), "SCInlineVisualDim" },
  }
end

return M
