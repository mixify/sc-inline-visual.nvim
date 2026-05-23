(
~scvisAddr = NetAddr("127.0.0.1", 57121);

SynthDef(\scvis_monitor, {
    var sig, amp, centroid, chain;
    sig = InFeedback.ar(0, 2).sum;
    amp = Amplitude.kr(sig, 0.01, 0.1);
    chain = FFT(LocalBuf(1024), sig);
    centroid = SpecCentroid.kr(chain);
    SendReply.kr(Impulse.kr(15), '/scvis/data', [amp, centroid]);
}).add;

~scvisStartMonitor = {
    fork {
        s.bootSync;
        // Don't free old — CmdPeriod already killed it
        ~scvisMonitor = Synth.after(s.defaultGroup, \scvis_monitor);
        "SCInlineVisual monitor running".postln;
    };
};

OSCdef(\scvisReply).free;
OSCdef(\scvisReply, { |msg|
    ~scvisAddr.sendMsg("/sc/analysis", "_master", msg[3], msg[4]);
}, '/scvis/data').fix;  // .fix = survive CmdPeriod

// Remove any previous handler before adding
~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) };
~scvisOnCmdPeriod = {
    ~scvisMonitor = nil;
    ~scvisAddr.sendMsg("/sc/analysis", "_cmdperiod", 0, 0);
    AppClock.sched(0.5, { ~scvisStartMonitor.value; nil });
};
CmdPeriod.add(~scvisOnCmdPeriod);

~scvisStartMonitor.value;
)
