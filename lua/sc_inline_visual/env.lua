-- Parse SuperCollider Env/EnvGen constructors from source text.
-- Normalizes each form into a list of breakpoints: { {t=<time>, v=<level>,
-- c=<curve>}, ... }. `c` is the curve of the segment *ending* at that point —
-- a number (SC curve value, 0 = linear) or one of the named curves below; the
-- first point and any omitted `c` are linear. The widget applies it.

local M = {}

-- SC curve symbols → canonical tokens the widget interpolator understands.
-- Anything unrecognised (squared/cubed/…) degrades to linear rather than erroring.
local NAMED = {
  lin = "lin", linear = "lin",
  exp = "exp", exponential = "exp",
  sin = "sin", sine = "sin",
  wel = "wel", welch = "wel",
  step = "step", hold = "hold",
}

local function parse_numbers(str)
  local nums = {}
  for n in str:gmatch("[%-%d%.]+") do
    local v = tonumber(n)
    if v then nums[#nums + 1] = v end
  end
  return nums
end

-- One curve token: `\sym` → canonical name, else a number, else linear.
local function curve_token(tok)
  local sym = tok:match("\\(%a+)")
  if sym then return NAMED[sym] or "lin" end
  return tonumber((tok:gsub("%s", ""))) or 0
end

-- The single curve arg of a fixed-shape Env (perc/adsr/…): a `\symbol` anywhere
-- in the args, else the numeric at positional index `num_index`, else `default`.
-- (Positional, like the rest of this parser — keyword-arg curves resolve only
-- when written as a symbol.)
local function scalar_curve(args, num_index, default)
  local sym = args:match("\\(%a+)")
  if sym then return NAMED[sym] or "lin" end
  local n = parse_numbers(args)
  if n[num_index] ~= nil then return n[num_index] end
  return default
end

-- Env.perc(attack=0.01, release=1, level=1, curve=-4)
local function parse_perc(args)
  local n = parse_numbers(args)
  local a, r, lev = n[1] or 0.01, n[2] or 1, n[3] or 1
  local c = scalar_curve(args, 4, -4)
  return { { t = 0, v = 0 }, { t = a, v = lev, c = c }, { t = a + r, v = 0, c = c } }
end

-- Env.triangle(dur=1, level=1) — always linear
local function parse_triangle(args)
  local n = parse_numbers(args)
  local d, lev = n[1] or 1, n[2] or 1
  return { { t = 0, v = 0 }, { t = d / 2, v = lev }, { t = d, v = 0 } }
end

-- Env.sine(dur=1, level=1) — sampled half-sine (curvature already in the points)
local function parse_sine(args)
  local n = parse_numbers(args)
  local d, lev = n[1] or 1, n[2] or 1
  local pts, STEPS = {}, 8
  for i = 0, STEPS do
    pts[#pts + 1] = { t = (i / STEPS) * d, v = math.sin(math.pi * i / STEPS) * lev }
  end
  return pts
end

-- Env.linen(attack=0.01, sustain=1, release=1, level=1, curve=\lin)
local function parse_linen(args)
  local n = parse_numbers(args)
  local a, s, r, lev = n[1] or 0.01, n[2] or 1, n[3] or 1, n[4] or 1
  local c = scalar_curve(args, 5, "lin")
  return {
    { t = 0, v = 0 },
    { t = a, v = lev, c = c },
    { t = a + s, v = lev, c = c },
    { t = a + s + r, v = 0, c = c },
  }
end

-- Env.adsr(attack=0.01, decay=0.3, sustain=0.5, release=1, peak=1, curve=-4)
-- sustain is a *level* (0..1). Draw a synthetic sustain segment for visualization.
local function parse_adsr(args)
  local n = parse_numbers(args)
  local a, d, s, r, peak = n[1] or 0.01, n[2] or 0.3, n[3] or 0.5, n[4] or 1, n[5] or 1
  local c = scalar_curve(args, 6, -4)
  local sus_dur = math.max(a + d, r) * 0.7
  return {
    { t = 0, v = 0 },
    { t = a, v = peak, c = c },
    { t = a + d, v = s * peak, c = c },
    { t = a + d + sus_dur, v = s * peak, c = c },
    { t = a + d + sus_dur + r, v = 0, c = c },
  }
end

-- Env.asr(attack=0.01, sustain=1, release=1, curve=-4) — sustain is a level
local function parse_asr(args)
  local n = parse_numbers(args)
  local a, s, r = n[1] or 0.01, n[2] or 1, n[3] or 1
  local c = scalar_curve(args, 4, -4)
  local sus_dur = math.max(a, r) * 0.7
  return {
    { t = 0, v = 0 },
    { t = a, v = s, c = c },
    { t = a + sus_dur, v = s, c = c },
    { t = a + sus_dur + r, v = 0, c = c },
  }
end

-- Per-segment curves for Env.new's optional 3rd arg `curve` (default \lin):
-- `\sym` or a number applies to every segment; `[c1, c2, …]` is per-segment and
-- wraps (SC semantics) if shorter than the segment count.
local function new_curves(rest, nseg)
  local out = {}
  local arr = rest:match("%[(.-)%]")
  if arr and arr:match("%S") then
    local list = {}
    for tok in arr:gmatch("[^,]+") do
      list[#list + 1] = curve_token(tok)
    end
    if #list > 0 then
      for j = 1, nseg do
        out[j] = list[((j - 1) % #list) + 1]
      end
      return out
    end
  end
  local sym = rest:match("\\(%a+)")
  local scalar = sym and (NAMED[sym] or "lin") or parse_numbers(rest)[1] or "lin"
  for j = 1, nseg do
    out[j] = scalar
  end
  return out
end

-- Env.new([levels], [times], curve?) and bare Env([levels], [times], curve?)
local function parse_new(args)
  local levels_str, times_str = args:match("%[(.-)%]%s*,%s*%[(.-)%]")
  if not levels_str or not times_str then return nil end
  local levels, times = parse_numbers(levels_str), parse_numbers(times_str)
  if #levels < 2 or #times < 1 then return nil end
  -- The curve arg, if any, follows the two arrays.
  local _, l1e = args:find("%[.-%]")
  local _, t1e = args:find("%[.-%]", (l1e or 0) + 1)
  local curves = new_curves(args:sub((t1e or 0) + 1), #times)
  local pts = { { t = 0, v = levels[1] } }
  local t = 0
  for i = 1, #times do
    t = t + times[i]
    pts[#pts + 1] = { t = t, v = levels[i + 1] or levels[#levels], c = curves[i] }
  end
  return pts
end

local DISPATCH = {
  perc = parse_perc,
  triangle = parse_triangle,
  sine = parse_sine,
  linen = parse_linen,
  adsr = parse_adsr,
  dadsr = parse_adsr,
  asr = parse_asr,
  new = parse_new,
}

-- Given the position of "(", scan forward to the matching ")", honoring nesting.
local function find_matching(source, lp)
  local depth, i = 1, lp + 1
  while i <= #source do
    local ch = source:sub(i, i)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then return i end
    end
    i = i + 1
  end
  return nil
end

--- Parse the first recognizable Env/EnvGen envelope from a block source.
--- Returns { kind = "perc"|"adsr"|..., points = { {t,v}, ... } } or nil.
function M.parse(source)
  -- 1. Env.<kind>(...)  — frontier prevents matching `myEnv.foo`
  local idx = 1
  while idx <= #source do
    local s, e, kind = source:find("%f[%w]Env%.(%w+)%s*%(", idx)
    if not s then break end
    local parser = DISPATCH[kind]
    if parser then
      local lp = source:find("%(", s)
      local rp = lp and find_matching(source, lp)
      if lp and rp then
        local pts = parser(source:sub(lp + 1, rp - 1))
        if pts then return { kind = kind, points = pts } end
      end
    end
    idx = e + 1
  end

  -- 2. Bare Env([levels], [times])  — frontier rejects EnvGen
  local s = source:find("%f[%w]Env%s*%(")
  if s then
    local lp = source:find("%(", s)
    local rp = lp and find_matching(source, lp)
    if lp and rp then
      local pts = parse_new(source:sub(lp + 1, rp - 1))
      if pts then return { kind = "new", points = pts } end
    end
  end

  return nil
end

return M
