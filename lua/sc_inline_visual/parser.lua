-- Scan a Neovim buffer for SuperCollider blocks via tree-sitter
-- (madskjeldgaard/tree-sitter-supercollider).
--
-- Recognises:
--   * Parenthesised blocks `( ... )` (code_block)
--   * Single-line / multi-line `{ ... }.play` (function_call w/ function_block receiver)
--   * Named constructs: Ndef(\name, ...), Pdef(\name, ...), SynthDef(\name, ...),
--     Tdef(\name, ...), Pbindef(\name, ...) (function_call w/ class receiver + first symbol arg)
--   * Explicit markers: `// @vis <name>` on the line above any of the above

local M = {}

local NAMED_CLASSES = {
  Ndef = "ndef",
  Pdef = "pdef",
  SynthDef = "synthdef",
  Tdef = "tdef",
  Pbindef = "pdef",
}

local function symbol_text(s)
  if s:sub(1, 1) == "\\" then return s:sub(2) end
  if s:sub(1, 1) == "'" and s:sub(-1) == "'" then return s:sub(2, -2) end
  return s
end

-- Walk into a node looking for the first descendant `symbol` literal.
local function first_symbol(node, bufnr)
  for child in node:iter_children() do
    if child:type() == "symbol" then
      return symbol_text(vim.treesitter.get_node_text(child, bufnr))
    end
    local found = first_symbol(child, bufnr)
    if found then return found end
  end
  return nil
end

-- (name, kind) if `node` is a class call like `Ndef(\foo, ...)`; nil otherwise.
local function detect_named(node, bufnr)
  if node:type() ~= "function_call" then return nil end
  local receivers = node:field("receiver")
  local receiver = receivers and receivers[1]
  if not receiver or receiver:type() ~= "class" then return nil end
  local class_name = vim.treesitter.get_node_text(receiver, bufnr)
  local kind = NAMED_CLASSES[class_name]
  if not kind then return nil end
  local args = node:field("arguments")
  if not (args and args[1]) then return nil end
  local name = first_symbol(args[1], bufnr)
  if not name then return nil end
  return name, kind
end

-- Walk inside a code_block looking for the first named construct call.
local function detect_named_in_block(node, bufnr)
  local stack = { node }
  while #stack > 0 do
    local n = table.remove(stack)
    local name, kind = detect_named(n, bufnr)
    if name then return name, kind end
    for child in n:iter_children() do
      stack[#stack + 1] = child
    end
  end
  return nil
end

-- True if any child identifier of `node` is "play" (i.e. a `.play` chain).
local function has_play_call(node, bufnr)
  for child in node:iter_children() do
    if child:type() == "identifier"
      and vim.treesitter.get_node_text(child, bufnr) == "play"
    then
      return true
    end
  end
  return false
end

function M.scan(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "supercollider")
  if not ok or not parser then return {} end
  local trees = parser:parse()
  if not (trees and trees[1]) then return {} end
  local root = trees[1]:root()

  local blocks = {}
  local auto_id = 0
  local pending_marker = nil

  local function add_block(node, name, kind)
    local sr, _, er = node:range()
    blocks[#blocks + 1] = {
      target = name,
      kind = kind,
      start_line = sr,
      end_line = er,
    }
  end

  for child in root:iter_children() do
    local t = child:type()

    if t == "line_comment" then
      local text = vim.treesitter.get_node_text(child, bufnr)
      local marker = text:match("^//+%s*@vis%s+(%S+)")
      if marker then pending_marker = marker end
    elseif t == "code_block" then
      if pending_marker then
        add_block(child, pending_marker, "anonymous")
        pending_marker = nil
      else
        local name, kind = detect_named_in_block(child, bufnr)
        if not name then
          auto_id = auto_id + 1
          name = "block" .. auto_id
          kind = "anonymous"
        end
        add_block(child, name, kind)
      end
    elseif t == "function_call" then
      local name, kind = detect_named(child, bufnr)
      if name then
        if pending_marker then
          name = pending_marker
          kind = "anonymous"
          pending_marker = nil
        end
        add_block(child, name, kind)
      elseif has_play_call(child, bufnr) then
        if pending_marker then
          add_block(child, pending_marker, "anonymous")
          pending_marker = nil
        else
          auto_id = auto_id + 1
          add_block(child, "block" .. auto_id, "anonymous")
        end
      end
    end
  end

  return blocks
end

return M
