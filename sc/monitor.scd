// Install SCInlineVisual monitoring on the SC server.
// Sent in one shot from lua/sc_inline_visual/init.lua (M._install_monitor)
// via vim.fn.readfile.
//
// Layout (Symbol -> value):
//   ~scvisAddr            NetAddr to Neovim OSC listener
//   ~scvisNdefMonitors    explicit-Ndef monitor synths
//   ~scvisParentBuses     per-block shared audio bus
//   ~scvisParentRouters   per-block bus -> out 0 router
//   ~scvisParentMonitors  per-block FFT/amp monitor
//   ~scvisNdefMap         parent name -> tid (stable across CmdPeriod for OSC routing)
(
~scvisAddr = NetAddr("127.0.0.1", {{PORT}});

[\scvisNdefMonitors, \scvisParentBuses, \scvisParentRouters, \scvisParentMonitors]
    .do { |k| currentEnvironment[k] = currentEnvironment[k] ? IdentityDictionary.new };

~scvisNdefMap    = ~scvisNdefMap    ? IdentityDictionary.new;
~scvisNdefNextID = ~scvisNdefNextID ? 0;

~scvisStartMonitor = {
    fork {
        s.bootSync;

        SynthDef(\scvis_monitor, {
            var sig = InFeedback.ar(0, 2).sum;
            var amp = Amplitude.kr(sig, 0.005, 0.05);
            var chain = FFT(LocalBuf(256), sig);
            var centroid = SpecCentroid.kr(chain);
            SendReply.kr(Impulse.kr({{FPS}}), '/scvis/data', [amp, centroid]);
        }).add;

        SynthDef(\scvis_ndef_monitor, { |busIndex = 0, targetID = 0|
            var sig = In.ar(busIndex, 2).sum;
            var amp = Amplitude.kr(sig, 0.005, 0.05);
            var chain = FFT(LocalBuf(256), sig);
            var centroid = SpecCentroid.kr(chain);
            SendReply.kr(Impulse.kr({{FPS}}), '/scvis/ndef', [targetID, amp, centroid]);
        }).add;

        SynthDef(\scvis_parent_router, { |inBus = 0, outBus = 0, amp = 1.0|
            Out.ar(outBus, In.ar(inBus, 2) * amp);
        }).add;

        s.sync;

        ~scvisMonitor = Synth.after(s.defaultGroup, \scvis_monitor);
        "SCInlineVisual monitor running".postln;
    };
};

// For explicit Ndef blocks the user authored themselves.
~scvisTrackNdef = { |name|
    fork {
        var ndef, busIdx, tid;
        s.sync;
        ndef = Ndef(name.asSymbol);
        if(ndef.bus.notNil) {
            busIdx = ndef.bus.index;
            tid = ~scvisNdefMap.at(name.asSymbol);
            if(tid.isNil) {
                tid = ~scvisNdefNextID;
                ~scvisNdefNextID = ~scvisNdefNextID + 1;
                ~scvisNdefMap.put(name.asSymbol, tid);
            };
            ~scvisNdefMonitors.put(
                name.asSymbol,
                Synth.after(ndef.group, \scvis_ndef_monitor,
                    [\busIndex, busIdx, \targetID, tid])
            );
            ("SCInlineVisual: tracking Ndef " ++ name ++ " bus:" ++ busIdx ++ " id:" ++ tid).postln;
        };
    };
};

// Each call shares the per-block bus, so concurrent .play invocations from the
// same source location no longer overwrite each other (the previous Ndef-singleton
// wrap silently dropped all but the most recent caller).
~scvisPlayWrap = { |parentName, body|
    var sym = parentName.asSymbol;
    var bus = ~scvisParentBuses.at(sym);
    if(bus.isNil) {
        bus = Bus.audio(s, 2);
        ~scvisParentBuses.put(sym, bus);
        fork {
            var tid, router, monitor;
            s.sync;
            tid = ~scvisNdefMap.at(sym);
            if(tid.isNil) {
                tid = ~scvisNdefNextID;
                ~scvisNdefNextID = ~scvisNdefNextID + 1;
                ~scvisNdefMap.put(sym, tid);
            };
            router = Synth.tail(s.defaultGroup, \scvis_parent_router,
                [\inBus, bus.index, \outBus, 0]);
            ~scvisParentRouters.put(sym, router);
            monitor = Synth.after(router, \scvis_ndef_monitor,
                [\busIndex, bus.index, \targetID, tid]);
            ~scvisParentMonitors.put(sym, monitor);
            ("SCInlineVisual: parent " ++ parentName ++ " bus:" ++ bus.index ++ " id:" ++ tid).postln;
        };
    };
    { Out.ar(~scvisParentBuses.at(sym).index, SynthDef.wrap(body)) }
};

OSCdef(\scvisReply).free;
OSCdef(\scvisReply, { |msg|
    ~scvisAddr.sendMsg("/sc/analysis", "_master", msg[3], msg[4])
}, '/scvis/data').fix;

OSCdef(\scvisNdefReply).free;
OSCdef(\scvisNdefReply, { |msg|
    var tid = msg[3].asInteger;
    var name = ~scvisNdefMap.findKeyForValue(tid);
    if(name.notNil) {
        ~scvisAddr.sendMsg("/sc/analysis", name.asString, msg[4], msg[5])
    };
}, '/scvis/ndef').fix;

// On CmdPeriod the server frees every synth, so the dict values are stale refs —
// just clear them. Buses are client-side allocator state and MUST be .free'd, or
// the next bus index will collide. ~scvisNdefMap is intentionally preserved so a
// reused parent name keeps the same tid (OSC routing stays consistent).
~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) };
~scvisOnCmdPeriod = {
    ~scvisMonitor = nil;
    ~scvisParentBuses.do { |bus| bus.free };
    [~scvisNdefMonitors, ~scvisParentBuses, ~scvisParentRouters, ~scvisParentMonitors]
        .do(_.clear);
    AppClock.sched(0.5, { ~scvisStartMonitor.value; nil });
};
CmdPeriod.add(~scvisOnCmdPeriod);

~scvisStartMonitor.value;
)
