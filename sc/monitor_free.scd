(
~scvisMonitor !? { ~scvisMonitor.free; ~scvisMonitor = nil };
OSCdef(\scvisReply).free;
~scvisOnCmdPeriod !? { CmdPeriod.remove(~scvisOnCmdPeriod) };
~scvisOnCmdPeriod = nil;
"SCInlineVisual monitor stopped".postln;
)
