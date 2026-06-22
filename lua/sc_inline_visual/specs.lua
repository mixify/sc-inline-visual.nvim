-- Standard SuperCollider ControlSpecs, mirrored from `Spec.specs`. Single source
-- of truth: `scrub.lua` clamps the keyboard slider to these ranges, and the
-- renderer's slider widget draws the handle inside them. Each entry is
-- `{ min, max, warp }` with warp "lin" or "exp" — exp specs all have min > 0.

local M = {}

local TWO_PI = 6.2831853072

local SPECS = {
  unipolar     = { 0, 1, "lin" },
  bipolar      = { -1, 1, "lin" },
  freq         = { 20, 20000, "exp" },
  lofreq       = { 0.1, 100, "exp" },
  midfreq      = { 25, 4200, "exp" },
  widefreq     = { 0.1, 20000, "exp" },
  phase        = { 0, TWO_PI, "lin" },
  rq           = { 0.001, 2, "exp" },
  amp          = { 0, 1, "lin" }, -- SC warps amp on a curve; linear is fine for a handle dot
  boostcut     = { -20, 20, "lin" },
  pan          = { -1, 1, "lin" },
  detune       = { -20, 20, "lin" },
  rate         = { 0.125, 8, "exp" },
  beats        = { 0, 20, "lin" },
  delay        = { 0.0001, 1, "exp" },
  midi         = { 0, 127, "lin" },
  midinote     = { 0, 127, "lin" },
  midivelocity = { 1, 127, "lin" },
}

--- The full spec `{ min, max, warp }` for a control name, or nil.
function M.get(name)
  return SPECS[name]
end

--- Just the `{ min, max }` range — what scrub needs to clamp a step.
function M.bounds(name)
  local s = SPECS[name]
  return s and { s[1], s[2] }
end

--- Map `value` to its 0..1 position within `spec`, honoring the spec's warp
--- (so a frequency handle sits where the ear expects). Out-of-range values
--- clamp to the ends.
function M.unmap(spec, value)
  local lo, hi, warp = spec[1], spec[2], spec[3]
  value = math.max(lo, math.min(hi, value))
  if warp == "exp" then
    return math.log(value / lo) / math.log(hi / lo)
  end
  return (value - lo) / (hi - lo)
end

return M
