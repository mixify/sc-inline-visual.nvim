local osc = require("sc_inline_visual.osc")
local parser = require("sc_inline_visual.parser")
local state = require("sc_inline_visual.state")
local renderer = require("sc_inline_visual.renderer")

local M = {}

local running = false
local timer = nil
local bufnr = nil
local eval_hook_id = nil
local rescan_autocmd_id = nil
local on_send_replaced = false

-- Locate the SC helper files relative to this plugin
local _this_file = debug.getinfo(1, "S").source:match("@(.*)")
local _plugin_root = vim.fn.fnamemodify(_this_file, ":h:h:h") .. "/"

local function send_to_sclang(code)
  local ok, sclang = pcall(require, "scnvim.sclang")
  if ok and sclang.is_running() then
    sclang.send(code)
    return true
  end
  return false
end

--- Send multiple SC statements sequentially with small delays between them.
local function send_sc_sequence(statements)
  local i = 1
  local function send_next()
    if i > #statements then return end
    send_to_sclang(statements[i])
    i = i + 1
    if i <= #statements then
      vim.defer_fn(send_next, 100)
    end
  end
  send_next()
end

function M.start()
  if running then
    vim.notify("SCInlineVisual: already running", vim.log.levels.WARN)
    return
  end

  bufnr = vim.api.nvim_get_current_buf()
  local blocks = parser.scan(bufnr)
  if #blocks == 0 then
    vim.notify("SCInlineVisual: no blocks found", vim.log.levels.WARN)
    return
  end

  state.init(blocks)
  renderer.init(bufnr)

  -- Listen for OSC
  osc.start(function(msg_type, target, ...)
    if target == "_cmdperiod" then return end
    state.update(msg_type, target, ...)
  end)

  -- Send monitor synth to sclang — sent as individual statements
  M._install_monitor()

  -- Replace scnvim's on_send to wrap anonymous blocks in Ndef
  local ok_editor, editor = pcall(require, "scnvim.editor")
  if ok_editor and editor.on_send and editor.on_send.replace then
    local ok_sclang, sclang = pcall(require, "scnvim.sclang")
    if ok_sclang then
      editor.on_send:replace(function(lines, callback)
        if callback then
          lines = callback(lines)
        end

        local code = table.concat(lines, "\n")

        -- Find which block the cursor is in
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = cursor[1] - 1
        local target, kind = state.activate_by_line(line)

        -- Wrap anonymous blocks in Ndef for per-block monitoring
        local ndef_name = nil
        if target and kind == "anonymous" then
          local wrapped, name = M._wrap_in_ndef(code, target)
          if wrapped ~= code then
            code = wrapped
            ndef_name = name
            -- Register alias so SC data for "scvis_block3" routes to "block3"
            state.set_alias(ndef_name, target)
          end
        end

        sclang.send(code)

        -- Set up per-ndef monitoring after a delay
        local track_name = ndef_name or (kind == "ndef" and target) or nil
        if track_name then
          vim.defer_fn(function()
            send_to_sclang(string.format('~scvisTrackNdef.value("%s")', track_name))
          end, 500)
        end
      end)
      on_send_replaced = true
    end
  end

  -- Auto-rescan when buffer text changes
  rescan_autocmd_id = vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    callback = function()
      if running then
        local blocks = parser.scan(bufnr)
        state.init(blocks)
      end
    end,
  })

  -- Render loop at ~30 FPS (33ms)
  timer = vim.uv.new_timer()
  timer:start(0, 33, vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      M.stop()
      return
    end
    renderer.render(bufnr, state.get_all())
  end))

  running = true
  local names = {}
  for _, b in ipairs(blocks) do names[#names + 1] = b.target end
  vim.notify("SCInlineVisual: started (" .. #blocks .. " blocks)", vim.log.levels.INFO)
end

function M.stop()
  if not running then return end

  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end

  -- Remove autocmd
  if rescan_autocmd_id then
    vim.api.nvim_del_autocmd(rescan_autocmd_id)
    rescan_autocmd_id = nil
  end

  -- Restore scnvim's original on_send
  if on_send_replaced then
    local ok_editor, editor = pcall(require, "scnvim.editor")
    if ok_editor and editor.on_send and editor.on_send.restore then
      editor.on_send:restore()
    end
    on_send_replaced = false
  end

  osc.stop()
  renderer.clear(bufnr)
  state.reset()
  M._remove_monitor()

  running = false
  vim.notify("SCInlineVisual: stopped", vim.log.levels.INFO)
end

function M.toggle()
  if running then
    M.stop()
  else
    M.start()
  end
end

--- Wrap `{ ... }.play` in `Ndef(\name, { ... }).play` for per-block monitoring.
--- Returns the transformed code and the ndef name, or original code if no transformation.
function M._wrap_in_ndef(code, target)
  -- Skip if already contains Ndef/Pdef
  if code:match("Ndef%s*%(") or code:match("Pdef%s*%(") then
    return code, nil
  end

  -- Find }.play pattern (possibly with whitespace/newline between } and .play)
  local play_pattern = "}%s*%.play"
  local close_start, close_end = code:find(play_pattern)
  if not close_start then return code, nil end

  -- Find the matching { by counting braces backwards from the }
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

  if not open_brace then return code, nil end

  local ndef_name = "scvis_" .. target
  local prefix = code:sub(1, open_brace - 1)
  local func_body = code:sub(open_brace, close_start) -- { ... }
  local suffix = code:sub(close_start + 1)             -- .play...

  return prefix .. "Ndef(\\" .. ndef_name .. ", " .. func_body .. ")" .. suffix, ndef_name
end

function M._install_monitor()
  if not send_to_sclang('"SCInlineVisual: installing monitor...".postln') then
    vim.notify("SCInlineVisual: sclang not running", vim.log.levels.WARN)
    return
  end

  send_sc_sequence({
    -- 1. Set up address + storage
    '~scvisAddr = NetAddr("127.0.0.1", 57121); ~scvisNdefMonitors = ~scvisNdefMonitors ? IdentityDictionary.new',

    -- 2. SynthDefs: amp + centroid + 16-sample waveform (one cycle via Phasor sync).
    -- Ultra-light: ~5 UGens, 1 SendReply at 30fps. Just amp + centroid.
    table.concat({
      '~scvisStartMonitor = { fork { s.bootSync;',
      'SynthDef(\\scvis_monitor, {',
      '  var sig = InFeedback.ar(0, 2).sum;',
      '  var amp = Amplitude.kr(sig, 0.005, 0.05);',
      '  var chain = FFT(LocalBuf(256), sig);',
      '  var centroid = SpecCentroid.kr(chain);',
      '  SendReply.kr(Impulse.kr(30), \'/scvis/data\', [amp, centroid]);',
      '}).add;',
      'SynthDef(\\scvis_ndef_monitor, { |busIndex = 0, targetID = 0|',
      '  var sig = In.ar(busIndex, 2).sum;',
      '  var amp = Amplitude.kr(sig, 0.005, 0.05);',
      '  var chain = FFT(LocalBuf(256), sig);',
      '  var centroid = SpecCentroid.kr(chain);',
      '  SendReply.kr(Impulse.kr(30), \'/scvis/ndef\', [targetID, amp, centroid]);',
      '}).add;',
      's.sync;',
      '~scvisMonitor = Synth.after(s.defaultGroup, \\scvis_monitor);',
      '"SCInlineVisual monitor running".postln } }',
    }, " "),

    -- 3. Per-Ndef track function
    '~scvisNdefMap = ~scvisNdefMap ? IdentityDictionary.new; ~scvisNdefNextID = ~scvisNdefNextID ? 0; ~scvisTrackNdef = { |name| fork { var ndef, busIdx, tid; s.sync; ndef = Ndef(name.asSymbol); if(ndef.bus.notNil, { busIdx = ndef.bus.index; tid = ~scvisNdefMap.at(name.asSymbol); if(tid.isNil, { tid = ~scvisNdefNextID; ~scvisNdefNextID = ~scvisNdefNextID + 1; ~scvisNdefMap.put(name.asSymbol, tid) }); ~scvisNdefMonitors.put(name.asSymbol, Synth.after(ndef.group, \\scvis_ndef_monitor, [\\busIndex, busIdx, \\targetID, tid])); ("SCInlineVisual: tracking Ndef " ++ name ++ " bus:" ++ busIdx ++ " id:" ++ tid).postln }) } }',

    -- 4. OSCdef for master bus — .fix survives CmdPeriod
    'OSCdef(\\scvisReply).free; OSCdef(\\scvisReply, { |msg| ~scvisAddr.sendMsg("/sc/analysis", "_master", msg[3], msg[4]) }, \'/scvis/data\').fix',

    -- 5. OSCdef for per-Ndef data
    'OSCdef(\\scvisNdefReply).free; OSCdef(\\scvisNdefReply, { |msg| var tid = msg[3].asInteger; var amp = msg[4]; var centroid = msg[5]; var name = ~scvisNdefMap.findKeyForValue(tid); if(name.notNil, { ~scvisAddr.sendMsg("/sc/analysis", name.asString, amp, centroid) }) }, \'/scvis/ndef\').fix',

    -- 6. CmdPeriod handler — restart master + clear ndef monitors.
    --    Do NOT call .free on monitors (CmdPeriod already freed all synths).
    '~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) }; ~scvisOnCmdPeriod = { ~scvisMonitor = nil; ~scvisNdefMonitors.clear; AppClock.sched(0.5, { ~scvisStartMonitor.value; nil }) }; CmdPeriod.add(~scvisOnCmdPeriod)',

    -- 7. Start the master monitor
    '~scvisStartMonitor.value',
  })
end

function M._remove_monitor()
  send_sc_sequence({
    '~scvisMonitor !? { ~scvisMonitor.free; ~scvisMonitor = nil }',
    'OSCdef(\\scvisReply).free',
    '~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) }; ~scvisOnCmdPeriod = nil',
    '"SCInlineVisual monitor stopped".postln',
  })
end

function M.list()
  local buf = bufnr or vim.api.nvim_get_current_buf()
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
  local blocks = parser.scan(bufnr)
  state.init(blocks)
  vim.notify("SCInlineVisual: rescanned, found " .. #blocks .. " blocks", vim.log.levels.INFO)
end

return M
