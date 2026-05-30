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

// Allocate (or look up) the per-block bus, router, and monitor synth set, and
// return the bus index. Pure plumbing — no audio side effects on the user's
// graph. Called by ~scvisWrap and anything else that wants the per-block bus.
~scvisEnsureBus = { |parentName|
    var sym = parentName.asSymbol;
    if(~scvisParentBuses.at(sym).isNil) {
        var bus = Bus.audio(s, 2);
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
    ~scvisParentBuses.at(sym).index
};

// Polymorphic decorator. Routes `target` so its audio writes go through the
// per-block bus instead of out 0 — what gets returned depends on the type:
//   Function: a new function `{ Out.ar(bus, body.value) }` ready for `.play`
//   Pattern:  a Pbindf-wrapped pattern with \out overridden, ready for `.play`
//   Event:    the same Event with `\out` keyed to the bus, ready for `.play`
//             (covers the common `(instrument: \name, ...).play` idiom)
// Note: Pattern and Event clauses silently override any user-supplied `\out`.
// Adding support for a new playable type is a single case clause.
~scvisWrap = { |parentName, target|
    var bus = ~scvisEnsureBus.value(parentName);
    case
        { target.isKindOf(Function) } { { Out.ar(bus, SynthDef.wrap(target)) } }
        { target.isKindOf(Pattern)  } { Pbindf(target, \out, bus) }
        { target.isKindOf(Event)    } { target.put(\out, bus); target }
        { target };
};

// Back-compat alias for the prior wrap name — same surface signature.
~scvisPlayWrap = ~scvisWrap;

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

// Free a single parent block's bus/router/monitor (idle GC from Lua side).
// ~scvisNdefMap is intentionally kept so a recurring block name keeps the same tid.
~scvisFreeParent = { |parentName|
    var sym = parentName.asSymbol;
    ~scvisParentMonitors.at(sym) !? { |s| s.free };
    ~scvisParentRouters .at(sym) !? { |s| s.free };
    ~scvisParentBuses   .at(sym) !? { |b| b.free };
    ~scvisParentMonitors.removeAt(sym);
    ~scvisParentRouters .removeAt(sym);
    ~scvisParentBuses   .removeAt(sym);
    ("SCInlineVisual: freed parent " ++ parentName).postln;
};

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
