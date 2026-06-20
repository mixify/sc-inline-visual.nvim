-- Parse SuperCollider pattern data from source code text.
-- Extracts Pseq, Prand, Pxrand arrays and Pbind key-value pairs.

local M = {}

local DEGREE_TO_NOTE = { [0] = "C", "D", "E", "F", "G", "A", "B" }

--- Parse a SC array literal: [1, 2, 3] or [0.25, 0.5]
--- Returns a list of numbers, or nil if not parseable.
local function parse_array(str)
  local inner = str:match("%[(.-)%]")
  if not inner then return nil end
  local vals = {}
  for v in inner:gmatch("([%-%d%.]+)") do
    local n = tonumber(v)
    if n then vals[#vals + 1] = n end
  end
  if #vals == 0 then return nil end
  return vals
end

--- Extract the array from a pattern constructor:
--- Pseq([1,2,3], inf) → {1,2,3}
--- Prand([1,2,3], inf) → {1,2,3}
--- Also handles plain array: [1,2,3]
local function parse_pattern_values(text)
  -- Pseq([...], ...) or Prand([...], ...) etc.
  local arr_str = text:match("Pseq%s*(%[.-%])")
    or text:match("Prand%s*(%[.-%])")
    or text:match("Pxrand%s*(%[.-%])")
    or text:match("Pser%s*(%[.-%])")
    or text:match("Pwrand%s*(%[.-%])")
    or text:match("Pshuf%s*(%[.-%])")
  if arr_str then return parse_array(arr_str) end
  -- Plain array
  return parse_array(text)
end

--- Extract the pattern type: Pseq, Prand, etc.
local function parse_pattern_type(text)
  return text:match("(Pseq)")
    or text:match("(Prand)")
    or text:match("(Pxrand)")
    or text:match("(Pser)")
    or text:match("(Pshuf)")
    or text:match("(Pwhite)")
    or text:match("(Pexprand)")
    or "seq"
end

--- Parse a Pbind/Pbindef block and extract key-pattern pairs.
--- Input: the full source text of the block.
--- Returns: { {key="dur", values={0.25,0.25,0.5}, type="Pseq"}, ... } or nil
function M.parse_pbind(source)
  -- Check if this is a Pbind/Pbindef
  if not source:match("Pbind") and not source:match("Pbindef") then return nil end

  local params = {}

  -- Match \key, PatternExpr patterns across the source
  -- Strategy: find each \key and grab everything until the next \key or closing )
  for key, rest in source:gmatch("\\(%w+)%s*,%s*([^\\]+)") do
    local values = parse_pattern_values(rest)
    local ptype = parse_pattern_type(rest)

    if values then
      params[#params + 1] = {
        key = key,
        values = values,
        type = ptype,
      }
    elseif rest:match("Pwhite") then
      -- Pwhite(lo, hi) — continuous range
      local lo, hi = rest:match("Pwhite%s*%(([%-%d%.]+)%s*,%s*([%-%d%.]+)")
      if lo and hi then
        params[#params + 1] = {
          key = key,
          range = { tonumber(lo), tonumber(hi) },
          type = "Pwhite",
        }
      end
    end
  end

  if #params == 0 then return nil end
  return params
end

--- Which Pbind key's value-expression is the cursor on? `lines` are the block's
--- source lines, `start_line` their 0-indexed buffer offset, `params` the
--- parsed key list, and `cur_line`/`cur_col` the 0-indexed cursor position.
---
--- A key owns everything from its own `\key` token up to the *next* key token,
--- so the answer is the word of the last `\word,` token at or before the cursor
--- — but only if that word is actually a rendered key. Every `\word` followed
--- by a comma is treated as a region boundary (so a non-rendered key like
--- `\scale` still ends the previous key's region, yielding nil rather than
--- leaking the highlight onto it); symbol *values* like `\minor` aren't
--- followed by a comma, so they're ignored. Avoids needing a full parse.
function M.key_at_cursor(lines, start_line, params, cur_line, cur_col)
  if not params or #params == 0 then return nil end
  local keyset = {}
  for _, p in ipairs(params) do
    keyset[p.key] = true
  end

  local best_word, best_l, best_c = nil, -1, -1
  for li, line in ipairs(lines) do
    local abs_line = start_line + li - 1
    local idx = 1
    while true do
      local s, e, kw = line:find("\\(%w+)", idx)
      if not s then break end
      if line:sub(e + 1):match("^%s*,") then -- a key token (value, comma follows)
        local kc = s - 1 -- 0-indexed column of the backslash
        local at_or_before = (abs_line < cur_line) or (abs_line == cur_line and kc <= cur_col)
        local later_than_best = (abs_line > best_l) or (abs_line == best_l and kc > best_c)
        if at_or_before and later_than_best then
          best_word, best_l, best_c = kw, abs_line, kc
        end
      end
      idx = e + 1
    end
  end
  return keyset[best_word] and best_word or nil
end

--- Convert degree number to note name.
function M.degree_to_note(deg)
  -- Handle negative degrees and octave wrapping
  local oct_offset = math.floor(deg / 7)
  local d = deg % 7
  if d < 0 then
    d = d + 7
    oct_offset = oct_offset - 1
  end
  local name = DEGREE_TO_NOTE[d] or "?"
  if oct_offset ~= 0 then
    name = name .. (oct_offset > 0 and ("+" .. oct_offset) or tostring(oct_offset))
  end
  return name
end

M.midi_to_note = require("sc_inline_visual.music").midi_to_note

return M
