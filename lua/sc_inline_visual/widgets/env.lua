-- Envelope preview: render a parsed Env shape (perc / adsr / new / ...) as a
-- multi-row braille plot. Picks one of two strategies based on point count:
--   - Filled bars  (≤ 9 points)  — good for ADSR-like discrete envelopes
--   - Line plot    (≥ 10 points) — drawille-style, good for sampled shapes

local braille = require("sc_inline_visual.widgets.braille")
local LEFT_DOTS = braille.LEFT_DOTS
local RIGHT_DOTS = braille.RIGHT_DOTS

local WIDTH = 22 -- chars per row
local ROWS = 3 -- braille rows → 12 vertical levels per character column
local SLOTS = WIDTH * 2
local V_MAX = ROWS * 4

local ROW_HL = {
  [3] = { "SCInlineVisualAmpHot", "SCInlineVisualAmpHigh", "SCInlineVisualAmpLow" },
  [2] = { "SCInlineVisualAmpHigh", "SCInlineVisualAmpLow" },
  [1] = { "SCInlineVisualAmpMid" },
}

local M = {}

local HALF_PI = math.pi / 2

--- Interpolate a single segment `y1`→`y2` at position `pos` (0..1) using the
--- segment's `curve` — a number (SC curve value, 0 ≈ linear) or a named curve.
--- Mirrors SuperCollider's `Env` segment shapes so the plot matches what plays.
local function curve_interp(y1, y2, pos, curve)
  if type(curve) == "string" then
    if curve == "step" then
      return y2 -- jump to target immediately
    elseif curve == "hold" then
      return (pos < 1) and y1 or y2 -- hold start, jump at the very end
    elseif curve == "sin" then
      return y1 + (y2 - y1) * (0.5 - 0.5 * math.cos(math.pi * pos)) -- S-curve
    elseif curve == "wel" then
      if y1 < y2 then
        return y1 + (y2 - y1) * math.sin(HALF_PI * pos)
      end
      return y1 + (y2 - y1) * (1 - math.cos(HALF_PI * pos))
    elseif curve == "exp" then
      -- Exponential needs same-sign, nonzero ends; otherwise fall back linear.
      local a = (math.abs(y1) < 1e-5) and (y1 < 0 and -1e-5 or 1e-5) or y1
      local b = (math.abs(y2) < 1e-5) and (y2 < 0 and -1e-5 or 1e-5) or y2
      if (a > 0) == (b > 0) then
        return a * (b / a) ^ pos
      end
      return y1 + (y2 - y1) * pos
    end
    return y1 + (y2 - y1) * pos -- "lin" / unknown
  end
  -- Numeric SC curve value.
  local c = curve or 0
  if math.abs(c) < 1e-4 then
    return y1 + (y2 - y1) * pos
  end
  return y1 + (y2 - y1) * (1 - math.exp(pos * c)) / (1 - math.exp(c))
end

--- Sample an envelope at time `t`, normalised by max |value|, honoring each
--- segment's curve (the `c` on the segment's end point; nil = linear).
local function make_level_at(pts, max_v)
  return function(t)
    if t <= pts[1].t then return pts[1].v / max_v end
    for i = 2, #pts do
      if t <= pts[i].t then
        local span = pts[i].t - pts[i - 1].t
        local frac = span > 0 and (t - pts[i - 1].t) / span or 0
        return curve_interp(pts[i - 1].v, pts[i].v, frac, pts[i].c) / max_v
      end
    end
    return pts[#pts].v / max_v
  end
end

--- Per-slot normalised level array (length SLOTS, values 0..1).
local function sample_levels(level_at, total_t)
  local levels = {}
  for i = 0, SLOTS - 1 do
    local t = (i / (SLOTS - 1)) * total_t
    levels[i + 1] = math.max(0, math.min(1, level_at(t)))
  end
  return levels
end

--- Filled-bar encoder: each row r covers vertical band [r*4 .. r*4+3].
local function row_chars_bar(levels, r)
  local offset = (ROWS - 1 - r) * 4
  local chars = {}
  for i = 1, SLOTS, 2 do
    local left = math.max(0, math.min(4, math.floor(levels[i] * V_MAX + 0.5) - offset))
    local right = math.max(0, math.min(4, math.floor(levels[i + 1] * V_MAX + 0.5) - offset))
    local code = 0x2800
    for j = 1, left do
      code = code + LEFT_DOTS[j]
    end
    for j = 1, right do
      code = code + RIGHT_DOTS[j]
    end
    chars[#chars + 1] = vim.fn.nr2char(code)
  end
  return table.concat(chars)
end

--- Build a SLOTS×V_MAX boolean pixel grid with vertical line-fills, then
--- return a `row_chars(r)` callable that encodes one braille row at a time.
local function make_line_plotter(levels)
  local pixels = {}
  for y = 0, V_MAX - 1 do
    pixels[y] = {}
    for x = 1, SLOTS do
      pixels[y][x] = false
    end
  end

  local function plot(x, y)
    if y < 0 or y >= V_MAX or x < 1 or x > SLOTS then return end
    pixels[y][x] = true
  end

  local prev_y
  for x = 1, SLOTS do
    -- y=0 at top, V_MAX-1 at bottom — high level → low y.
    local y = math.floor((1 - levels[x]) * (V_MAX - 1) + 0.5)
    if prev_y and math.abs(prev_y - y) > 1 then
      local lo, hi = math.min(prev_y, y), math.max(prev_y, y)
      for yy = lo, hi do
        plot(x, yy)
      end
    else
      plot(x, y)
    end
    prev_y = y
  end

  return function(r)
    local chars = {}
    for c = 1, WIDTH do
      local lx, rx = (c - 1) * 2 + 1, (c - 1) * 2 + 2
      local code = 0x2800
      for dot = 0, 3 do
        local y = r * 4 + dot
        local idx = 4 - dot -- LEFT_DOTS index (1=bottom, 4=top)
        if pixels[y][lx] then code = code + LEFT_DOTS[idx] end
        if pixels[y][rx] then code = code + RIGHT_DOTS[idx] end
      end
      chars[#chars + 1] = vim.fn.nr2char(code)
    end
    return table.concat(chars)
  end
end

--- Multi-row envelope preview for a parsed Env shape.
--- Input: `{ kind = "perc"|"adsr"|..., points = { {t,v}, ... } }`.
--- Returns nil for unrenderable shapes (no points / zero duration).
function M.env_preview(env)
  if not env or not env.points or #env.points < 2 then return nil end
  local pts = env.points
  local total_t = pts[#pts].t
  if total_t <= 0 then return nil end

  local max_v, peak = 0, 0
  for _, p in ipairs(pts) do
    if math.abs(p.v) > max_v then
      max_v = math.abs(p.v)
      peak = p.v -- signed peak level — the y-axis extent
    end
  end
  if max_v == 0 then max_v = 1 end

  local levels = sample_levels(make_level_at(pts, max_v), total_t)
  local row_chars
  if #pts >= 10 then
    row_chars = make_line_plotter(levels)
  else
    row_chars = function(r)
      return row_chars_bar(levels, r)
    end
  end

  local hls = ROW_HL[ROWS] or { "SCInlineVisualAmpMid" }
  -- Axis readouts: y = peak level (top row), x = total time span (bottom row).
  local dur_str = total_t < 1 and string.format("%.0fms", total_t * 1000)
    or string.format("%.2fs", total_t)
  local y_top = string.format("↑%g", peak) -- y-axis: peak level
  local x_bot = "0–" .. dur_str -- x-axis: 0 → duration

  local rows = {}
  for r = 0, ROWS - 1 do
    local hl = hls[r + 1] or "SCInlineVisualAmpMid"
    -- The left gutter doubles as the y scale: peak at top, baseline at bottom.
    local gutter = (r == 0 and "env  ") or (r == ROWS - 1 and "   0 ") or "     "
    local row = {
      { gutter, "SCInlineVisualDim" },
      { row_chars(r), hl },
    }
    if r == 0 then
      row[#row + 1] = { "  " .. env.kind .. " " .. y_top, "SCInlineVisualDim" }
    elseif r == ROWS - 1 then
      row[#row + 1] = { "  " .. x_bot, "SCInlineVisualDim" }
    end
    rows[#rows + 1] = row
  end
  return rows
end

return M
