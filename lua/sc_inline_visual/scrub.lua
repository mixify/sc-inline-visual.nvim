-- Keyboard "slider": nudge the numeric literal under the cursor and, when it
-- maps to a live-settable control, push the new value to SC with no recompile —
-- the Bret-Victor "drag a number, hear it change" loop, keyboard-driven.
--
-- Glitch-free live update is attempted for the three cases SC can update without
-- rebuilding a synth:
--   * an Ndef NamedControl default  — `\freq.kr(440)` → `Ndef(\name).set(\freq, v)`
--   * a Pbindef key's scalar value  — `\dur, 0.25`    → `Pbindef(\name, \dur, v)`
--   * a synth-function arg default bound to a persistent var — `x = { |freq =
--     220| … }.play` → `x.set(\freq, v)` (the var, not the plugin's block name,
--     is the handle; `SynthDef.wrap` keeps the arg a control through the eval-wrap)
-- Anything else still edits the buffer text (so the next eval picks it up) but
-- isn't pushed live. When the control name is a standard SuperCollider
-- ControlSpec the step is clamped to that spec's range (see `specs.lua`, the
-- shared source the slider widget also draws from). The pure functions here are
-- unit-tested; the buffer edit and the send live in init.lua.

local specs = require("sc_inline_visual.specs")

local M = {}

local function round(x)
  return (x >= 0) and math.floor(x + 0.5) or math.ceil(x - 0.5)
end

--- Locate the numeric literal under (or immediately after) the 0-indexed
--- column `col0` in `line`. Returns `{ s, e, value, decimals }` with `s`/`e`
--- 1-indexed inclusive Lua-string bounds, or nil. A leading `-` is folded into
--- the literal only when it reads as a unary minus (preceded by an operator or
--- an opener), never when it's a subtraction. Method receivers like `5.rand`
--- and embedded digits like the `0` in `LFNoise0` are intentionally skipped.
function M.find_number(line, col0)
  local p = col0 + 1
  local init = 1
  while true do
    local s, e = line:find("%d*%.?%d+", init)
    if not s then return nil end

    local prev2 = (s > 1) and line:sub(s - 1, s - 1) or ""
    local nxt = line:sub(e + 1, e + 1)
    -- Reject if glued to an identifier (LFNoise0, a1) or a method call (5.rand).
    local glued = prev2:match("[%w_]") or nxt:match("[%w_.]")

    -- Fold a unary minus into the token.
    local ts = s
    if prev2 == "-" then
      local before_minus = (s >= 3) and line:sub(s - 2, s - 2) or ""
      if before_minus == "" or before_minus:match("[%s%(%[{,=*/+<>:]") then
        ts = s - 1
      end
    end

    if not glued and p >= ts and p <= e + 1 then
      local text = line:sub(ts, e)
      local dot = text:find(".", 1, true) -- literal-dot search (plain)
      local decimals = dot and (#text - dot) or 0
      return { s = ts, e = e, value = tonumber(text), decimals = decimals }
    end
    init = e + 1
  end
end

--- Apply `steps` increments of the literal's own least-significant digit to a
--- token, preserving its written precision. Returns the formatted text. `steps`
--- is signed (already folded with direction, big step and count by the caller).
--- `bounds` is an optional `{ min, max }` that clamps the result to a control's
--- spec range.
function M.step_value(token, steps, bounds)
  local factor = 10 ^ token.decimals
  local new_value = round(token.value * factor + steps) / factor
  if bounds then
    new_value = math.min(math.max(new_value, bounds[1]), bounds[2])
  end
  if token.decimals == 0 then
    return string.format("%d", new_value)
  end
  return string.format("%." .. token.decimals .. "f", new_value)
end

-- Live-settable forms, each matched by a line-prefix capture of the control/arg
-- name just before the number. `target`-keyed kinds (`block`/`fmt`) confirm the
-- enclosing block contains `block`..target and format `(target, name, value)`;
-- `handle` kinds instead read the bound variable out of the block (see
-- `M.command`).
local SETTABLE = {
  -- Ndef NamedControl default: `\ctl.kr( <num>`
  { before = "\\(%w+)%.[ka]r%s*%(%s*$", block = "Ndef%s*%(%s*\\",   fmt = "Ndef(\\%s).set(\\%s, %s)" },
  -- Pbindef key's scalar value: `\key, <num>`
  { before = "\\(%w+)%s*,%s*$",         block = "Pbindef%s*%(%s*\\", fmt = "Pbindef(\\%s, \\%s, %s)" },
  -- Synth-function arg default: `|freq = <num>` / `, amp = <num>` / `arg freq = <num>`
  { before = "[|,]%s*([%a_][%w_]*)%s*=%s*$", handle = true },
  { before = "arg%s+([%a_][%w_]*)%s*=%s*$",  handle = true },
}

--- Identify the settable control whose value is the number at 1-indexed bounds
--- `num_s`..`num_e` on `line`. Line-only (cheap): returns `{ name, kind }` with
--- `kind` the matched `SETTABLE` row, or nil. The caller reads the enclosing
--- block — to confirm the kind and build the command — only when this is
--- non-nil, so the costly block read stays gated behind the line test.
function M.detect(line, num_s, num_e)
  local before = line:sub(1, num_s - 1)
  local after = line:sub(num_e + 1)
  -- The literal must be a complete value: arg/key separator, closer, or EOL.
  if not (after:match("^%s*[,)|;]") or after:match("^%s*$")) then return nil end
  for _, kind in ipairs(SETTABLE) do
    local name = before:match(kind.before)
    if name then return { name = name, kind = kind } end
  end
  return nil
end

--- Range `{ min, max }` for a standard SuperCollider control name, or nil.
function M.spec_bounds(name)
  return specs.bounds(name)
end

--- Scan a block's source `lines` for the settable controls whose value is a
--- numeric literal AND whose name has a known ControlSpec, in first-seen order
--- (deduped by name). Returns `{ { name, value, spec }, … }` — what the slider
--- widget renders. Reuses the same per-line `find_number`/`detect` the keyboard
--- slider uses, so the sliders shown are exactly the numbers scrub can move.
function M.scan_controls(lines)
  local out, seen = {}, {}
  for _, line in ipairs(lines) do
    local init = 1
    while true do
      local ms, me = line:find("%d*%.?%d+", init)
      if not ms then break end
      init = me + 1
      local token = M.find_number(line, ms - 1)
      -- Accept only when find_number locks onto the literal at this position
      -- (so glued digits like the 0 in LFNoise0 are skipped, not mis-read).
      if token and token.s <= ms and ms <= token.e then
        local d = M.detect(line, token.s, token.e)
        if d and not seen[d.name] then
          local spec = specs.get(d.name)
          if spec then
            seen[d.name] = true
            out[#out + 1] = { name = d.name, value = token.value, spec = spec }
          end
        end
      end
    end
  end
  return out
end

--- Build the live-update command for `detected` (from `M.detect`), given the
--- enclosing `block_source`, the plugin `target`, and the already-formatted
--- `value_str`. Returns the SC command string, or nil when the block doesn't
--- confirm the kind (wrong/absent target, or no bound variable for an arg
--- default — a bare `{ … }.play` has no handle to `.set`).
function M.command(detected, target, block_source, value_str)
  local kind = detected.kind
  if kind.handle then
    -- The handle is the persistent var the synth function is assigned to.
    local var = block_source:match("(~?[%a][%w_]*)%s*=%s*{")
    if not var then return nil end
    return string.format("%s.set(\\%s, %s)", var, detected.name, value_str)
  end
  if not target then return nil end
  if not block_source:find(kind.block .. vim.pesc(target)) then return nil end
  return string.format(kind.fmt, target, detected.name, value_str)
end

return M
