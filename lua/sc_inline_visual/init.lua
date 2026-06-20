local config = require("sc_inline_visual.config")
local osc = require("sc_inline_visual.osc")
local parser = require("sc_inline_visual.parser")
local pattern = require("sc_inline_visual.pattern")
local state = require("sc_inline_visual.state")
local renderer = require("sc_inline_visual.renderer")

local M = {}

local running = false
local timer = nil
local gc_timer = nil
local tracked_bufs = {} -- bufnr -> { rescan_autocmd_id }
local on_send_replaced = false

local _this_file = debug.getinfo(1, "S").source:match("@(.*)")
local _plugin_root = vim.fn.fnamemodify(_this_file, ":h:h:h") .. "/"

--- Merge user opts into the module-wide config table in place. Other modules
--- (osc.lua, health.lua) read from the same table so changes take effect
--- without re-requiring.
function M.setup(opts)
  if type(opts) == "table" then
    for k, v in pairs(opts) do
      config[k] = v
    end
  end
end

local function send_to_sclang(code)
  local ok, sclang = pcall(require, "scnvim.sclang")
  if ok and sclang.is_running() then
    sclang.send(code)
    return true
  end
  return false
end

local function load_sc(name)
  local text = table.concat(vim.fn.readfile(_plugin_root .. "sc/" .. name), "\n")
  text = text:gsub("{{PORT}}", tostring(config.port))
  text = text:gsub("{{FPS}}", tostring(config.render_fps))
  text = text:gsub("{{PREVIEW_COUNT}}", tostring(config.pattern_preview_count))
  return text
end

local function notify(msg, level)
  if config.notify then vim.notify(msg, level or vim.log.levels.INFO) end
end

--- Replace scnvim's on_send hook so that every code chunk we send to sclang
--- gets routed through `~scvisWrap` for the block under the cursor (or
--- `~scvisTrackNdef` for explicit Ndefs). Idempotent and best-effort: silently
--- skips if scnvim isn't loaded or the on_send API isn't available.
local function setup_on_send_replacer()
  if on_send_replaced then return end
  local ok_editor, editor = pcall(require, "scnvim.editor")
  if not (ok_editor and editor.on_send and editor.on_send.replace) then return end
  local ok_sclang, sclang = pcall(require, "scnvim.sclang")
  if not ok_sclang then return end

  editor.on_send:replace(function(lines, callback)
    if callback then lines = callback(lines) end
    local code = table.concat(lines, "\n")

    local cur_buf = vim.api.nvim_get_current_buf()
    if not tracked_bufs[cur_buf] then M._add_buffer(cur_buf) end

    local cursor = vim.api.nvim_win_get_cursor(0)
    local target, kind = state.activate_by_line(cursor[1] - 1)

    if target and (kind == "anonymous" or kind == "pdef") then
      local wrapped, did_wrap = M._wrap_play_chain(code, target)
      if did_wrap then
        code = wrapped
        state.mark_wrapped(target)
      end
    elseif target and kind == "ndef" then
      state.mark_wrapped(target)
      vim.defer_fn(function()
        send_to_sclang(string.format('~scvisTrackNdef.value("%s")', target))
      end, 500)
    end

    sclang.send(code)
  end)

  on_send_replaced = true
end

function M.start()
  if running then
    vim.notify("SCInlineVisual: already running", vim.log.levels.WARN)
    return
  end

  -- Scan current buffer and add it
  local bufnr = vim.api.nvim_get_current_buf()
  M._add_buffer(bufnr)

  renderer.init(bufnr)

  -- Listen for OSC
  osc.start(function(msg_type, target, ...)
    if target == "_cmdperiod" then return end
    if msg_type == "pat_event" then
      state.record_event(target, ...)
    elseif msg_type == "pat_preview" then
      state.record_preview(target, ...)
    else
      state.update(msg_type, target, ...)
    end
  end)

  -- Send monitor synth to sclang
  M._install_monitor()

  setup_on_send_replacer()

  local interval_ms = math.max(1, math.floor(1000 / config.render_fps))
  timer = vim.uv.new_timer()
  timer:start(
    0,
    interval_ms,
    vim.schedule_wrap(function()
      local all = state.get_all()
      for buf, _ in pairs(tracked_bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          renderer.render(buf, all)
        else
          tracked_bufs[buf] = nil
        end
      end
    end)
  )

  if config.idle_gc_seconds > 0 then
    local check_ms = math.max(1, config.idle_gc_check_seconds) * 1000
    gc_timer = vim.uv.new_timer()
    gc_timer:start(
      check_ms,
      check_ms,
      vim.schedule_wrap(function()
        local now_s = vim.uv.hrtime() / 1e9
        for target, s in pairs(state.get_all()) do
          if
            s.monitored
            and s.last_update > 0
            and (now_s - s.last_update) > config.idle_gc_seconds
            and s.amp <= 0.005
          then
            send_to_sclang(string.format('~scvisFreeParent.value("%s")', target))
            state.unmark_wrapped(target)
          end
        end
      end)
    )
  end

  running = true
  notify("SCInlineVisual: started")
end

--- Recompute which Pbind key the cursor is on, for the block under the cursor,
--- and stash it in state so the renderer can highlight that row. Read-only with
--- respect to block activation — hovering a block must not start monitoring it.
local function update_cursor_highlight(bufnr)
  if not running then return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cur_line, cur_col = cursor[1] - 1, cursor[2]

  state.clear_cursor_keys()
  local target, start_line, end_line = state.target_at_line(cur_line)
  if not target then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  local params = pattern.parse_pbind(table.concat(lines, "\n"))
  if not params then return end

  state.set_cursor_key(target, pattern.key_at_cursor(lines, start_line, params, cur_line, cur_col))
end

--- Add a buffer for tracking. Scans for blocks and sets up auto-rescan.
function M._add_buffer(bufnr)
  if tracked_bufs[bufnr] then return end

  local blocks = parser.scan(bufnr)
  state.init(blocks) -- merges with existing state

  local ids = {}
  ids[#ids + 1] = vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    callback = function()
      if running then
        local b = parser.scan(bufnr)
        state.init(b)
      end
    end,
  })
  ids[#ids + 1] = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = bufnr,
    callback = function()
      update_cursor_highlight(bufnr)
    end,
  })

  tracked_bufs[bufnr] = { autocmd_ids = ids }
end

function M.stop()
  if not running then return end

  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end

  if gc_timer then
    gc_timer:stop()
    gc_timer:close()
    gc_timer = nil
  end

  -- Remove autocmds and clear extmarks for all tracked buffers
  for buf, info in pairs(tracked_bufs) do
    for _, id in ipairs(info.autocmd_ids or {}) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
    renderer.clear(buf)
  end
  tracked_bufs = {}

  -- Restore scnvim's original on_send
  if on_send_replaced then
    local ok_editor, editor = pcall(require, "scnvim.editor")
    if ok_editor and editor.on_send and editor.on_send.restore then editor.on_send:restore() end
    on_send_replaced = false
  end

  osc.stop()
  state.reset()
  M._remove_monitor()

  running = false
  notify("SCInlineVisual: stopped")
end

function M.toggle()
  if running then
    M.stop()
  else
    M.start()
  end
end

--- DFS for the first `function_call` whose `.method` part names `play`. The
--- TS grammar inlines the `_method_call` rule so the identifier appears as a
--- direct child of the function_call node alongside the receiver field.
local function find_play_call(node, source)
  if node:type() == "function_call" then
    for child in node:iter_children() do
      if child:type() == "identifier" and vim.treesitter.get_node_text(child, source) == "play" then
        return node
      end
    end
  end
  for child in node:iter_children() do
    local found = find_play_call(child, source)
    if found then return found end
  end
  return nil
end

--- Rewrite the first `<expr>.play` chain in `code` to route through the
--- per-block bus: `~scvisWrap.value("<target>", <expr>).play`. `<expr>` may
--- be a function block (`{ ... }`) or any expression whose method chain ends
--- in `.play` (`Pbind(...)`, `Pdef(\name, ...)`, `~seq.next(())`,
--- `(instrument: ...)`, etc.). The SC-side `~scvisWrap` dispatches on the
--- runtime type, so Lua doesn't need to distinguish.
---
--- Uses tree-sitter to walk the SC AST — same parser the buffer scanner uses,
--- so comments and string literals don't fool the match the way a regex
--- would. Returns `(transformed_code, true)` on success, `(code, false)`
--- when the grammar isn't loadable, no `.play` chain is present, or the user
--- already wrote an explicit `Ndef(` (those go through the dedicated
--- `~scvisTrackNdef` path).
function M._wrap_play_chain(code, target)
  if code:match("Ndef%s*%(") then return code, false end

  local ok, parser = pcall(vim.treesitter.get_string_parser, code, "supercollider")
  if not ok or not parser then return code, false end
  local trees = parser:parse()
  if not (trees and trees[1]) then return code, false end

  local call = find_play_call(trees[1]:root(), code)
  if not call then return code, false end

  local receivers = call:field("receiver")
  local receiver = receivers and receivers[1]
  if not receiver then return code, false end

  -- `node:start()` / `:end_()` give 0-indexed byte offsets; convert to Lua's
  -- 1-indexed inclusive substring bounds.
  local _, _, recv_start = receiver:start()
  local _, _, recv_end = receiver:end_()
  local recv_text = code:sub(recv_start + 1, recv_end)
  local prefix = code:sub(1, recv_start)
  local suffix = code:sub(recv_end + 1)

  return prefix .. '~scvisWrap.value("' .. target .. '", ' .. recv_text .. ")" .. suffix, true
end

function M._install_monitor()
  if not send_to_sclang('"SCInlineVisual: installing monitor...".postln') then
    vim.notify("SCInlineVisual: sclang not running", vim.log.levels.WARN)
    return
  end

  send_to_sclang(load_sc("monitor.scd"))
end

function M._remove_monitor()
  send_to_sclang(load_sc("monitor_free.scd"))
end

function M.list()
  local buf = vim.api.nvim_get_current_buf()
  local blocks = parser.scan(buf)
  if #blocks == 0 then
    vim.notify("No blocks found", vim.log.levels.INFO)
    return
  end
  local out = {}
  for _, b in ipairs(blocks) do
    out[#out + 1] = string.format("  %s (lines %d-%d)", b.target, b.start_line + 1, b.end_line + 1)
  end
  vim.notify("Blocks:\n" .. table.concat(out, "\n"), vim.log.levels.INFO)
end

function M.rescan()
  if not running then
    vim.notify("SCInlineVisual: not running", vim.log.levels.WARN)
    return
  end
  local blocks = parser.scan(vim.api.nvim_get_current_buf())
  state.init(blocks)
  vim.notify("SCInlineVisual: rescanned, found " .. #blocks .. " blocks", vim.log.levels.INFO)
end

return M
