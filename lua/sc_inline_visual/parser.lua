-- Scan buffer for SuperCollider blocks.
-- Supports:
--   1. Explicit markers: // @vis <target>
--   2. Named constructs: Ndef(\name, ...), SynthDef(\name, ...), Pdef(\name, ...)
--   3. Parenthesized blocks: ( ... ) starting at column 0
--   4. Inline .play blocks: { ... }.play

local M = {}

-- Try to extract a target name and kind from a line.
-- Returns name, kind ("ndef", "pdef", "synthdef", etc.) or nil, nil.
local function extract_name(line)
  local name
  name = line:match("Ndef%s*%(%s*\\(%w+)")
  if name then return name, "ndef" end
  name = line:match("Pdef%s*%(%s*\\(%w+)")
  if name then return name, "pdef" end
  name = line:match("SynthDef%s*%(%s*\\(%w+)")
  if name then return name, "synthdef" end
  name = line:match("Tdef%s*%(%s*\\(%w+)")
  if name then return name, "tdef" end
  name = line:match("Pbindef%s*%(%s*\\(%w+)")
  if name then return name, "pdef" end
  return nil, nil
end

-- Find matching closing paren/brace, tracking nesting.
-- `open` and `close` are the bracket characters.
-- Returns the 0-indexed line number of the closing bracket, or last line.
local function find_closing(lines, start_1indexed, open, close)
  local depth = 0
  for i = start_1indexed, #lines do
    local line = lines[i]
    for ch in line:gmatch(".") do
      if ch == open then
        depth = depth + 1
      elseif ch == close then
        depth = depth - 1
        if depth == 0 then
          return i - 1 -- 0-indexed
        end
      end
    end
  end
  return #lines - 1
end

function M.scan(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local seen_lines = {} -- track which lines are already part of a block

  -- Pass 1: explicit // @vis markers (highest priority)
  local marker_indices = {}
  for i, line in ipairs(lines) do
    local target = line:match("^%s*//+%s*@vis%s+(%S+)")
    if target then
      marker_indices[#marker_indices + 1] = i
      local start_line = i - 1 -- 0-indexed, the marker line itself

      -- Find the block end: look for next marker or end of file
      -- Then scan for a paren/brace block starting after the marker
      local block_end = start_line
      local next_line_1 = i + 1
      if next_line_1 <= #lines then
        local next_line = lines[next_line_1]
        if next_line:match("^%s*%(") then
          block_end = find_closing(lines, next_line_1, "(", ")")
        elseif next_line:match("^%s*{") or next_line:match("^%s*%a") then
          -- Scan until blank line or next marker
          for j = next_line_1, #lines do
            if lines[j]:match("^%s*$") or lines[j]:match("^%s*//+%s*@vis%s+") then
              break
            end
            block_end = j - 1
          end
        end
      end

      blocks[#blocks + 1] = {
        target = target,
        start_line = start_line,
        end_line = block_end,
      }
      for ln = start_line, block_end do
        seen_lines[ln] = true
      end
    end
  end

  -- Pass 2: auto-detect blocks
  local auto_id = 0
  local i = 1
  while i <= #lines do
    if seen_lines[i - 1] then
      i = i + 1
      goto continue
    end

    local line = lines[i]

    -- Skip blank lines and pure comments
    if line:match("^%s*$") or line:match("^%s*//") then
      i = i + 1
      goto continue
    end

    local target = nil
    local start_line = i - 1 -- 0-indexed
    local end_line = start_line

    -- Case A: Parenthesized block starting with ( at column 0
    local kind = nil
    if line:match("^%(") then
      end_line = find_closing(lines, i, "(", ")")

      -- Search inside the block for a named construct
      for j = i, end_line + 1 do
        if j <= #lines then
          target, kind = extract_name(lines[j])
          if target then break end
        end
      end

      if not target then
        auto_id = auto_id + 1
        target = "block" .. auto_id
        kind = "anonymous"
      end

      blocks[#blocks + 1] = {
        target = target,
        kind = kind,
        start_line = start_line,
        end_line = end_line,
      }
      for ln = start_line, end_line do
        seen_lines[ln] = true
      end
      i = end_line + 2 -- 1-indexed past block end
      goto continue
    end

    -- Case B: Single-line { ... }.play or named construct on one line
    if line:match("{.*}%s*%.play") or extract_name(line) then
      target, kind = extract_name(line)
      -- Could span multiple lines if braces don't close
      if line:match("{") and not line:match("}") then
        end_line = find_closing(lines, i, "{", "}")
      end

      if not target then
        auto_id = auto_id + 1
        target = "block" .. auto_id
        kind = "anonymous"
      end

      blocks[#blocks + 1] = {
        target = target,
        kind = kind,
        start_line = start_line,
        end_line = end_line,
      }
      for ln = start_line, end_line do
        seen_lines[ln] = true
      end
      i = end_line + 2
      goto continue
    end

    -- Case C: Named construct starting a multi-line block (not wrapped in parens)
    target, kind = extract_name(line)
    if target then
      -- Find the end — look for closing paren or semicolon
      if line:match("%(") then
        end_line = find_closing(lines, i, "(", ")")
      end

      blocks[#blocks + 1] = {
        target = target,
        kind = kind,
        start_line = start_line,
        end_line = end_line,
      }
      for ln = start_line, end_line do
        seen_lines[ln] = true
      end
      i = end_line + 2
      goto continue
    end

    i = i + 1
    ::continue::
  end

  return blocks
end

return M
