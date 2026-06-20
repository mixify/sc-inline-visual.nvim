-- Keyboard "slider": nudge the numeric literal under the cursor and, when it
-- maps to a live-settable control, push the new value to SC with no recompile —
-- the Bret-Victor "drag a number, hear it change" loop, keyboard-driven.
--
-- Glitch-free live update is only attempted for the two cases SC can `.set`
-- without rebuilding a synth:
--   * an Ndef NamedControl default — `\freq.kr(440)` → `Ndef(\name).set(\freq, v)`
--   * a Pbindef key's scalar value   — `\dur, 0.25`    → `Pbindef(\name, \dur, v)`
-- Anything else still edits the buffer text (so the next eval picks it up) but
-- isn't pushed live. The pure functions here are unit-tested; the buffer edit
-- and the send live in init.lua.

local M = {}

-- Escape Lua pattern magic so a target name can be interpolated into a search.
local function pesc(s)
  return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%1"))
end

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
--- token, preserving its written precision. Returns the new numeric value and
--- its formatted text. `steps` is signed (already folded with direction, big
--- step and count by the caller).
function M.step_value(token, steps)
  local ulp = 10 ^ (-token.decimals)
  local factor = 10 ^ token.decimals
  local new_value = round((token.value + steps * ulp) * factor) / factor
  local text
  if token.decimals == 0 then
    text = string.format("%d", round(new_value))
  else
    text = string.format("%." .. token.decimals .. "f", new_value)
  end
  return new_value, text
end

--- Build the glitch-free live-set command for the number at 1-indexed bounds
--- `num_s`..`num_e` on `line`, given the enclosing `block_source` and its
--- `target` name and the already-formatted `value_str`. Returns the SC command
--- string, or nil when the number isn't a live-settable Ndef/Pbindef control.
function M.resolve_command(line, num_s, num_e, block_source, target, value_str)
  if not target then return nil end
  local before = line:sub(1, num_s - 1)
  local after = line:sub(num_e + 1)
  -- The literal must be a complete value: end of arg list / next key, or EOL.
  if not (after:match("^%s*[,)]") or after:match("^%s*$")) then return nil end

  -- Ndef NamedControl default: `\ctl.kr( <num>`
  local ctl = before:match("\\(%w+)%.[ka]r%s*%(%s*$")
  if ctl then
    if block_source:find("Ndef%s*%(%s*\\" .. pesc(target)) then
      return string.format("Ndef(\\%s).set(\\%s, %s)", target, ctl, value_str)
    end
    return nil
  end

  -- Pbindef key's scalar value: `\key, <num>`
  local key = before:match("\\(%w+)%s*,%s*$")
  if key then
    if block_source:find("Pbindef%s*%(%s*\\" .. pesc(target)) then
      return string.format("Pbindef(\\%s, \\%s, %s)", target, key, value_str)
    end
    return nil
  end

  return nil
end

return M
