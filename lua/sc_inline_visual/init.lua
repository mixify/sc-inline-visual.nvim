local config = require("sc_inline_visual.config")
local osc = require("sc_inline_visual.osc")
local parser = require("sc_inline_visual.parser")
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
  return text
end

local function notify(msg, level)
  if config.notify then
    vim.notify(msg, level or vim.log.levels.INFO)
  end
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
    state.update(msg_type, target, ...)
  end)

  -- Send monitor synth to sclang
  M._install_monitor()

  -- Replace scnvim's on_send to wrap anonymous blocks in Ndef
  if not on_send_replaced then
    local ok_editor, editor = pcall(require, "scnvim.editor")
    if ok_editor and editor.on_send and editor.on_send.replace then
      local ok_sclang, sclang = pcall(require, "scnvim.sclang")
      if ok_sclang then
        editor.on_send:replace(function(lines, callback)
          if callback then
            lines = callback(lines)
          end

          local code = table.concat(lines, "\n")
          local cur_buf = vim.api.nvim_get_current_buf()

          -- Auto-add new .scd buffers
          if not tracked_bufs[cur_buf] then
            M._add_buffer(cur_buf)
          end

          -- Find which block the cursor is in
          local cursor = vim.api.nvim_win_get_cursor(0)
          local line = cursor[1] - 1
          local target, kind = state.activate_by_line(line)

          if target and kind == "anonymous" then
            local wrapped, did_wrap = M._wrap_in_ndef(code, target)
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
    end
  end

  local interval_ms = math.max(1, math.floor(1000 / config.render_fps))
  timer = vim.uv.new_timer()
  timer:start(0, interval_ms, vim.schedule_wrap(function()
    local all = state.get_all()
    for buf, _ in pairs(tracked_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        renderer.render(buf, all)
      else
        tracked_bufs[buf] = nil
      end
    end
  end))

  if config.idle_gc_seconds > 0 then
    local check_ms = math.max(1, config.idle_gc_check_seconds) * 1000
    gc_timer = vim.uv.new_timer()
    gc_timer:start(check_ms, check_ms, vim.schedule_wrap(function()
      local now_s = vim.uv.hrtime() / 1e9
      for target, s in pairs(state.get_all()) do
        if s.monitored
          and s.last_update > 0
          and (now_s - s.last_update) > config.idle_gc_seconds
          and s.amp <= 0.005
        then
          send_to_sclang(string.format('~scvisFreeParent.value("%s")', target))
          state.unmark_wrapped(target)
        end
      end
    end))
  end

  running = true
  notify("SCInlineVisual: started")
end

--- Add a buffer for tracking. Scans for blocks and sets up auto-rescan.
function M._add_buffer(bufnr)
  if tracked_bufs[bufnr] then return end

  local blocks = parser.scan(bufnr)
  state.init(blocks) -- merges with existing state

  local autocmd_id = vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    callback = function()
      if running then
        local b = parser.scan(bufnr)
        state.init(b)
      end
    end,
  })

  tracked_bufs[bufnr] = { autocmd_id = autocmd_id }
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
    if info.autocmd_id then
      pcall(vim.api.nvim_del_autocmd, info.autocmd_id)
    end
    renderer.clear(buf)
  end
  tracked_bufs = {}

  -- Restore scnvim's original on_send
  if on_send_replaced then
    local ok_editor, editor = pcall(require, "scnvim.editor")
    if ok_editor and editor.on_send and editor.on_send.restore then
      editor.on_send:restore()
    end
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

--- Wrap `{ body }.play` in `~scvisPlayWrap.value("target", { body }).play`
--- so every invocation of the user's `.play` writes into the same per-block bus
--- (SC side allocates bus + router + monitor lazily per parent target).
---
--- Returns `(transformed_code, true)` if wrapped, `(code, false)` otherwise.
--- Skips when the code already contains an explicit Ndef/Pdef.
function M._wrap_in_ndef(code, target)
  if code:match("Ndef%s*%(") or code:match("Pdef%s*%(") then
    return code, false
  end

  local play_pattern = "}%s*%.play"
  local close_start, _ = code:find(play_pattern)
  if not close_start then return code, false end

  local depth = 1
  local open_brace = nil
  for i = close_start - 1, 1, -1 do
    local ch = code:sub(i, i)
    if ch == "}" then
      depth = depth + 1
    elseif ch == "{" then
      depth = depth - 1
      if depth == 0 then
        open_brace = i
        break
      end
    end
  end
  if not open_brace then return code, false end

  local prefix = code:sub(1, open_brace - 1)
  local func_body = code:sub(open_brace, close_start) -- { ... }
  local suffix = code:sub(close_start + 1)             -- .play...

  return prefix
    .. "~scvisPlayWrap.value(\"" .. target .. "\", " .. func_body .. ")"
    .. suffix,
    true
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
