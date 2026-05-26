-- Parse SuperCollider Env/EnvGen constructors from source text.
-- Normalizes each form into a list of breakpoints: { {t=<time>, v=<level>}, ... }

local M = {}

local function parse_numbers(str)
  local nums = {}
  for n in str:gmatch("[%-%d%.]+") do
    local v = tonumber(n)
    if v then nums[#nums + 1] = v end
  end
  return nums
end

-- Env.perc(attack=0.01, release=1, level=1)
local function parse_perc(args)
  local n = parse_numbers(args)
  local a, r, lev = n[1] or 0.01, n[2] or 1, n[3] or 1
  return { { t = 0, v = 0 }, { t = a, v = lev }, { t = a + r, v = 0 } }
end

-- Env.triangle(dur=1, level=1)
local function parse_triangle(args)
  local n = parse_numbers(args)
  local d, lev = n[1] or 1, n[2] or 1
  return { { t = 0, v = 0 }, { t = d / 2, v = lev }, { t = d, v = 0 } }
end

-- Env.sine(dur=1, level=1) — sampled half-sine
local function parse_sine(args)
  local n = parse_numbers(args)
  local d, lev = n[1] or 1, n[2] or 1
  local pts, STEPS = {}, 8
  for i = 0, STEPS do
    pts[#pts + 1] = { t = (i / STEPS) * d, v = math.sin(math.pi * i / STEPS) * lev }
  end
  return pts
end

-- Env.linen(attack=0.01, sustain=1, release=1, level=1)
local function parse_linen(args)
  local n = parse_numbers(args)
  local a, s, r, lev = n[1] or 0.01, n[2] or 1, n[3] or 1, n[4] or 1
  return {
    { t = 0, v = 0 },
    { t = a, v = lev },
    { t = a + s, v = lev },
    { t = a + s + r, v = 0 },
  }
end

-- Env.adsr(attack=0.01, decay=0.3, sustain=0.5, release=1, peak=1)
-- sustain is a *level* (0..1). Draw a synthetic sustain segment for visualization.
local function parse_adsr(args)
  local n = parse_numbers(args)
  local a, d, s, r, peak = n[1] or 0.01, n[2] or 0.3, n[3] or 0.5, n[4] or 1, n[5] or 1
  local sus_dur = math.max(a + d, r) * 0.7
  return {
    { t = 0, v = 0 },
    { t = a, v = peak },
    { t = a + d, v = s * peak },
    { t = a + d + sus_dur, v = s * peak },
    { t = a + d + sus_dur + r, v = 0 },
  }
end

-- Env.asr(attack=0.01, sustain=1, release=1) — sustain is a level
local function parse_asr(args)
  local n = parse_numbers(args)
  local a, s, r = n[1] or 0.01, n[2] or 1, n[3] or 1
  local sus_dur = math.max(a, r) * 0.7
  return {
    { t = 0, v = 0 },
    { t = a, v = s },
    { t = a + sus_dur, v = s },
    { t = a + sus_dur + r, v = 0 },
  }
end

-- Env.new([levels], [times], ...) and bare Env([levels], [times])
local function parse_new(args)
  local levels_str, times_str = args:match("%[(.-)%]%s*,%s*%[(.-)%]")
  if not levels_str or not times_str then return nil end
  local levels, times = parse_numbers(levels_str), parse_numbers(times_str)
  if #levels < 2 or #times < 1 then return nil end
  local pts = { { t = 0, v = levels[1] } }
  local t = 0
  for i = 1, #times do
    t = t + times[i]
    pts[#pts + 1] = { t = t, v = levels[i + 1] or levels[#levels] }
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
