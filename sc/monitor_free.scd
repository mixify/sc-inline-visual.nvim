// Teardown sent when the plugin stops (M._remove_monitor).
(
~scvisMonitor !? { ~scvisMonitor.free; ~scvisMonitor = nil };
[~scvisParentRouters, ~scvisParentMonitors, ~scvisNdefMonitors].do { |dict|
    dict.do { |synth| synth.free };
    dict.clear;
};
~scvisParentBuses.do { |bus| bus.free };
~scvisParentBuses.clear;
OSCdef(\scvisReply).free;
OSCdef(\scvisNdefReply).free;
~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) };
~scvisOnCmdPeriod = nil;
"SCInlineVisual monitor stopped".postln;
)
