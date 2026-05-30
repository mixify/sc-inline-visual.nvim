local osc = require("sc_inline_visual.osc")
local parser = require("sc_inline_visual.parser")
local state = require("sc_inline_visual.state")
local renderer = require("sc_inline_visual.renderer")

local M = {}

local running = false
local timer = nil
local tracked_bufs = {} -- bufnr -> { rescan_autocmd_id }
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

          -- Wrap anonymous { ... }.play blocks so they route through the
          -- per-parent monitor bus (see ~scvisPlayWrap on SC side).
          local wrapped_anon = false
          if target and kind == "anonymous" then
            local wrapped, did_wrap = M._wrap_in_ndef(code, target)
            if did_wrap then
              code = wrapped
              wrapped_anon = true
              state.mark_wrapped(target)
            end
          end

          sclang.send(code)

          -- For explicit Ndef blocks the user wrote, attach a monitor synth
          -- to the Ndef bus (the ~scvisPlayWrap path handles this internally).
          if not wrapped_anon and kind == "ndef" and target then
            state.mark_wrapped(target)
            vim.defer_fn(function()
              send_to_sclang(string.format('~scvisTrackNdef.value("%s")', target))
            end, 500)
          end
        end)
        on_send_replaced = true
      end
    end
  end

  -- Render loop at ~30 FPS (33ms) — renders all tracked buffers
  timer = vim.uv.new_timer()
  timer:start(0, 33, vim.schedule_wrap(function()
    local all = state.get_all()
    for buf, _ in pairs(tracked_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        renderer.render(buf, all)
      else
        tracked_bufs[buf] = nil
      end
    end
  end))

  running = true
  vim.notify("SCInlineVisual: started", vim.log.levels.INFO)
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
  vim.notify("SCInlineVisual: stopped", vim.log.levels.INFO)
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

  send_sc_sequence({
    -- 1. Set up address + storage
    table.concat({
      '~scvisAddr = NetAddr("127.0.0.1", 57121);',
      '~scvisNdefMonitors  = ~scvisNdefMonitors  ? IdentityDictionary.new;',
      '~scvisParentBuses   = ~scvisParentBuses   ? IdentityDictionary.new;',
      '~scvisParentRouters = ~scvisParentRouters ? IdentityDictionary.new;',
      '~scvisParentMonitors= ~scvisParentMonitors? IdentityDictionary.new;',
    }, " "),

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
      'SynthDef(\\scvis_parent_router, { |inBus = 0, outBus = 0, amp = 1.0|',
      '  Out.ar(outBus, In.ar(inBus, 2) * amp);',
      '}).add;',
      's.sync;',
      '~scvisMonitor = Synth.after(s.defaultGroup, \\scvis_monitor);',
      '"SCInlineVisual monitor running".postln } }',
    }, " "),

    -- 3. Per-Ndef track function (for explicit Ndefs the user writes themselves)
    '~scvisNdefMap = ~scvisNdefMap ? IdentityDictionary.new; ~scvisNdefNextID = ~scvisNdefNextID ? 0; ~scvisTrackNdef = { |name| fork { var ndef, busIdx, tid; s.sync; ndef = Ndef(name.asSymbol); if(ndef.bus.notNil, { busIdx = ndef.bus.index; tid = ~scvisNdefMap.at(name.asSymbol); if(tid.isNil, { tid = ~scvisNdefNextID; ~scvisNdefNextID = ~scvisNdefNextID + 1; ~scvisNdefMap.put(name.asSymbol, tid) }); ~scvisNdefMonitors.put(name.asSymbol, Synth.after(ndef.group, \\scvis_ndef_monitor, [\\busIndex, busIdx, \\targetID, tid])); ("SCInlineVisual: tracking Ndef " ++ name ++ " bus:" ++ busIdx ++ " id:" ++ tid).postln }) } }',

    -- 3b. Per-block play wrapper: shared bus + persistent monitor per source block.
    --     `{ body }.play` becomes `~scvisPlayWrap.value("block3", { body }).play` so that
    --     EVERY invocation of the user's `.play` writes into the same per-block bus, and
    --     a single monitor synth reports analysis tagged with the block's tid.
    --     Maps allocated once-per-block: ~scvisParentBuses / Routers / Monitors / NdefMap.
    table.concat({
      '~scvisPlayWrap = { |parentName, body|',
      '  var sym = parentName.asSymbol;',
      '  var bus = ~scvisParentBuses.at(sym);',
      '  if(bus.isNil) {',
      '    bus = Bus.audio(s, 2);',
      '    ~scvisParentBuses.put(sym, bus);',
      '    fork {',
      '      var tid, router, monitor;',
      '      s.sync;',
      '      tid = ~scvisNdefMap.at(sym);',
      '      if(tid.isNil) {',
      '        tid = ~scvisNdefNextID;',
      '        ~scvisNdefNextID = ~scvisNdefNextID + 1;',
      '        ~scvisNdefMap.put(sym, tid);',
      '      };',
      '      router = Synth.tail(s.defaultGroup, \\scvis_parent_router,',
      '        [\\inBus, bus.index, \\outBus, 0]);',
      '      ~scvisParentRouters.put(sym, router);',
      '      monitor = Synth.after(router, \\scvis_ndef_monitor,',
      '        [\\busIndex, bus.index, \\targetID, tid]);',
      '      ~scvisParentMonitors.put(sym, monitor);',
      '      ("SCInlineVisual: parent " ++ parentName ++ " bus:" ++ bus.index ++ " id:" ++ tid).postln;',
      '    };',
      '  };',
      '  { Out.ar(~scvisParentBuses.at(sym).index, SynthDef.wrap(body)) }',
      '}',
    }, " "),

    -- 4. OSCdef for master bus — .fix survives CmdPeriod
    'OSCdef(\\scvisReply).free; OSCdef(\\scvisReply, { |msg| ~scvisAddr.sendMsg("/sc/analysis", "_master", msg[3], msg[4]) }, \'/scvis/data\').fix',

    -- 5. OSCdef for per-Ndef data
    'OSCdef(\\scvisNdefReply).free; OSCdef(\\scvisNdefReply, { |msg| var tid = msg[3].asInteger; var amp = msg[4]; var centroid = msg[5]; var name = ~scvisNdefMap.findKeyForValue(tid); if(name.notNil, { ~scvisAddr.sendMsg("/sc/analysis", name.asString, amp, centroid) }) }, \'/scvis/ndef\').fix',

    -- 6. CmdPeriod handler — restart master + clear ndef monitors.
    --    Do NOT call .free on synth refs (CmdPeriod already freed all synths).
    --    Buses MUST be freed (client-side allocator) and parent maps cleared so
    --    the next ~scvisPlayWrap call re-allocates fresh.
    --    ~scvisNdefMap is intentionally preserved so per-block tid stays stable
    --    across CmdPeriod cycles (OSC routing stays consistent).
    table.concat({
      '~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) };',
      '~scvisOnCmdPeriod = {',
      '  ~scvisMonitor = nil;',
      '  ~scvisNdefMonitors.clear;',
      '  ~scvisParentBuses.do({ |bus| bus.free });',
      '  ~scvisParentBuses.clear;',
      '  ~scvisParentRouters.clear;',
      '  ~scvisParentMonitors.clear;',
      '  AppClock.sched(0.5, { ~scvisStartMonitor.value; nil });',
      '};',
      'CmdPeriod.add(~scvisOnCmdPeriod)',
    }, " "),

    -- 7. Start the master monitor
    '~scvisStartMonitor.value',
  })
end

function M._remove_monitor()
  send_sc_sequence({
    '~scvisMonitor !? { ~scvisMonitor.free; ~scvisMonitor = nil }',
    '~scvisParentRouters.do({ |s| s.free }); ~scvisParentRouters.clear',
    '~scvisParentMonitors.do({ |s| s.free }); ~scvisParentMonitors.clear',
    '~scvisParentBuses.do({ |b| b.free }); ~scvisParentBuses.clear',
    '~scvisNdefMonitors.do({ |s| s.free }); ~scvisNdefMonitors.clear',
    'OSCdef(\\scvisReply).free; OSCdef(\\scvisNdefReply).free',
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
