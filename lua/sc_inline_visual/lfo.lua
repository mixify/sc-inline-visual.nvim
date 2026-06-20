-- Static simulation of control-rate UGen expressions for the inline sparkline.
--
-- This is the Victor-style "what values does this fragment produce over time"
-- view: we never run the SC server, we read the UGen out of the source and
-- synthesise a *representative* trace of its shape. For deterministic UGens
-- (SinOsc, LFSaw, ...) the shape is exact; for the noise family it's a stable,
-- seeded sample that conveys character (slow ramp vs stepped vs dense) rather
-- than the exact future values. The frequency sets the timescale, which we
-- surface in the label rather than the (necessarily windowed) sparkline.

local M = {}

local N = 16 -- samples / block-chars per sparkline
local CYCLES = 2.5 -- periodic cycles shown across the window
local NOISE_POINTS = 5 -- random control points shown for the LFNoise family

-- UGen name -> shape category. Anything not here isn't sparklined.
local SHAPES = {
  SinOsc = "sine", LFPar = "sine", LFCub = "sine", FSinOsc = "sine", Osc = "sine",
  LFTri = "tri", VarSaw = "tri",
  LFSaw = "saw", Saw = "saw", Phasor = "saw",
  LFPulse = "pulse", Pulse = "pulse",
  LFNoise0 = "step", LFDNoise0 = "step", LFClipNoise = "step",
  LFNoise1 = "ramp", LFDNoise1 = "ramp",
  LFNoise2 = "smooth", LFDNoise3 = "smooth",
  WhiteNoise = "white", ClipNoise = "white", GrayNoise = "white",
  PinkNoise = "pink",
  BrownNoise = "brown",
  Dust = "dust", Dust2 = "dust",
}

-- UGens whose first argument is a frequency (so we can show it in the label).
-- The noise UGens take freq too; WhiteNoise/PinkNoise/etc. don't.
local HAS_FREQ = {
  sine = true, tri = true, saw = true, pulse = true,
  step = true, ramp = true, smooth = true, dust = true,
}

local function frac(x)
  return x - math.floor(x)
end

local function clamp01(x)
  return math.max(0, math.min(1, x))
end

-- Tiny deterministic LCG so a given expression always renders the same trace
-- (no flicker on redraw); seeded from the matched source so distinct exprs
-- look distinct.
local function rng_from(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function()
    s = (s * 16807) % 2147483647
    return s / 2147483647
  end
end

-- djb2-style string hash (no bitwise ops, so it runs under LuaJIT/5.1).
local function hash(str)
  local h = 5381
  for i = 1, #str do
    h = (h * 33 + str:byte(i)) % 2147483647
  end
  return h
end

-- Random control points with the chosen interpolation, sampled to N values.
local function interp_noise(rng, mode)
  local pts = {}
  for i = 1, NOISE_POINTS + 1 do
    pts[i] = rng()
  end
  local out = {}
  for i = 1, N do
    local x = (i - 1) / (N - 1) * NOISE_POINTS
    local seg = math.floor(x)
    local mu = x - seg
    local a, b = pts[seg + 1], pts[seg + 2] or pts[seg + 1]
    if mode == "step" then
      out[i] = a
    elseif mode == "ramp" then
      out[i] = a + (b - a) * mu
    else -- smooth: cosine interpolation
      local mu2 = (1 - math.cos(mu * math.pi)) / 2
      out[i] = a + (b - a) * mu2
    end
  end
  return out
end

-- Generate the normalised (0..1) signal for a shape, pre range-warp.
local function gen_signal(shape, seed, width)
  local out = {}
  if shape == "sine" then
    for i = 1, N do
      out[i] = 0.5 + 0.5 * math.sin(2 * math.pi * (i - 1) / (N - 1) * CYCLES)
    end
  elseif shape == "saw" then
    for i = 1, N do
      out[i] = frac((i - 1) / (N - 1) * CYCLES)
    end
  elseif shape == "tri" then
    for i = 1, N do
      out[i] = 1 - math.abs(2 * frac((i - 1) / (N - 1) * CYCLES) - 1)
    end
  elseif shape == "pulse" then
    local w = width or 0.5
    for i = 1, N do
      out[i] = (frac((i - 1) / (N - 1) * CYCLES) < w) and 1 or 0
    end
  elseif shape == "step" or shape == "ramp" or shape == "smooth" then
    out = interp_noise(rng_from(seed), shape)
  elseif shape == "white" then
    local rng = rng_from(seed)
    for i = 1, N do
      out[i] = rng()
    end
  elseif shape == "pink" then
    local rng = rng_from(seed)
    local y = rng()
    for i = 1, N do
      y = 0.5 * y + 0.5 * rng()
      out[i] = y
    end
  elseif shape == "brown" then
    local rng = rng_from(seed)
    local y = 0.5
    for i = 1, N do
      y = clamp01(y + (rng() - 0.5) * 0.4)
      out[i] = y
    end
  elseif shape == "dust" then
    local rng = rng_from(seed)
    for i = 1, N do
      out[i] = (rng() < 0.28) and (0.4 + 0.6 * rng()) or 0
    end
  else
    return nil
  end
  return out
end

-- Map a normalised signal value through the range mapping for display. Linear
-- mappings leave the shape untouched (the bar height *is* the signal); exp
-- mappings warp it so the trace dwells low and spikes high, the way the audible
-- parameter actually moves.
local function warp(s, m)
  if m.exp and m.lo and m.hi and m.lo > 0 and m.hi > 0 then
    local v = m.lo * (m.hi / m.lo) ^ clamp01(s)
    return clamp01((v - m.lo) / (m.hi - m.lo))
  end
  return clamp01(s)
end

-- Find the range mapping applied to the UGen, scanning the source after it.
local function parse_mapping(rest)
  local lo, hi = rest:match("%.exprange%s*%(%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)")
  if lo then return { exp = true, lo = tonumber(lo), hi = tonumber(hi) } end
  lo, hi = rest:match("%.range%s*%(%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)")
  if lo then return { exp = false, lo = tonumber(lo), hi = tonumber(hi) } end
  -- linexp/linlin: take the LAST two numeric args as the output range.
  for kind, args in rest:gmatch("%.(lin%a%a%a)%s*(%b())") do
    local nums = {}
    for nstr in args:gmatch("%-?[%d%.]+") do
      nums[#nums + 1] = tonumber(nstr)
    end
    if #nums >= 2 then
      return { exp = (kind == "linexp"), lo = nums[#nums - 1], hi = nums[#nums] }
    end
  end
  if rest:match("%.unipolar") then return { exp = false, lo = 0, hi = 1 } end
  return { exp = false } -- no explicit range; show raw shape, no lo/hi label
end

local function fmt_num(n)
  if not n then return nil end
  local a = math.abs(n)
  if a >= 1000 then
    local s = string.format("%.1f", n / 1000):gsub("%.0$", "")
    return s .. "k"
  elseif a == math.floor(a) then
    return string.format("%d", n)
  else
    return string.format("%g", n)
  end
end

--- Detect the first sparklineable UGen on a single source line. Returns
--- `{ shape, freq, mapping, label }` or nil. Comments are stripped first so a
--- UGen name inside `// ...` doesn't trigger a false match.
function M.parse_line(line)
  local code = line:gsub("//.*$", "")
  -- Cheap reject before the per-UGen scan: no control-rate call → skip. We key
  -- on `.kr` specifically: `.ar` oscillators are the audible signal itself, not
  -- a slow control variable, and a 16-cell window can't represent audio rate.
  if not code:find("%.kr") then return nil end
  -- First known UGen with a `.kr` rate call.
  local best_pos, best_name, best_shape
  for name, shape in pairs(SHAPES) do
    local pos = code:find("%f[%w]" .. name .. "%.kr")
    if pos and (not best_pos or pos < best_pos) then
      best_pos, best_name, best_shape = pos, name, shape
    end
  end
  if not best_pos then return nil end

  local rest = code:sub(best_pos)
  local freq = tonumber(rest:match(best_name .. "%.kr%s*%(%s*(%-?[%d%.]+)"))
  -- Pulse width is only read from an explicit `width:` keyword arg; the
  -- positional form varies per UGen, so we fall back to the 0.5 default.
  local width = tonumber(rest:match("width:%s*([%d%.]+)"))
  local mapping = parse_mapping(rest)

  -- Label: "<freq>Hz <lo>–<hi>", dropping parts we don't know.
  local parts = {}
  if HAS_FREQ[best_shape] and freq then parts[#parts + 1] = fmt_num(freq) .. "Hz" end
  if mapping.lo and mapping.hi then
    parts[#parts + 1] = fmt_num(mapping.lo) .. "–" .. fmt_num(mapping.hi)
  end

  return {
    name = best_name,
    shape = best_shape,
    freq = freq,
    width = width,
    mapping = mapping,
    label = table.concat(parts, " "),
    seed = hash(rest:sub(1, 48)),
  }
end

--- Full pipeline for one line: parse + simulate. Returns `{ values, label }`
--- (values are N normalised 0..1 samples) or nil if the line has no UGen.
function M.analyze_line(line)
  local info = M.parse_line(line)
  if not info then return nil end
  local sig = gen_signal(info.shape, info.seed, info.width)
  if not sig then return nil end
  local values = {}
  for i = 1, #sig do
    values[i] = warp(sig[i], info.mapping)
  end
  return { values = values, label = info.label, name = info.name }
end

M.N = N

return M
