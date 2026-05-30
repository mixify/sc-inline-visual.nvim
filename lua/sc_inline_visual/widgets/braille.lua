-- Shared rendering primitives for the widget modules.

local M = {}

-- 8-step block characters for amplitude bars.
M.BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- Braille dot weights (U+2800..U+28FF). Each braille character is a 2-wide,
-- 4-tall dot matrix; LEFT_DOTS[i] / RIGHT_DOTS[i] is the code-point increment
-- for the i-th dot from the bottom of the left / right column.
M.LEFT_DOTS = { 0x40, 0x04, 0x02, 0x01 }
M.RIGHT_DOTS = { 0x80, 0x20, 0x10, 0x08 }

--- Pack two 0..1 levels into a single braille character (4 dots per column).
function M.braille_pair(v1, v2)
  local l = math.floor(math.max(0, math.min(1, v1)) * 4 + 0.5)
  local r = math.floor(math.max(0, math.min(1, v2)) * 4 + 0.5)
  local code = 0x2800
  for i = 1, math.min(l, 4) do
    code = code + M.LEFT_DOTS[i]
  end
  for i = 1, math.min(r, 4) do
    code = code + M.RIGHT_DOTS[i]
  end
  return vim.fn.nr2char(code)
end

--- Pick a highlight group based on amplitude level (0..1+).
function M.amp_hl(v)
  if v >= 0.8 then
    return "SCInlineVisualAmpHot"
  elseif v >= 0.5 then
    return "SCInlineVisualAmpHigh"
  elseif v >= 0.2 then
    return "SCInlineVisualAmpMid"
  else
    return "SCInlineVisualAmpLow"
  end
end

return M
