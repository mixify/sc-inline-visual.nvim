// Keyboard-slider playground.
//
// For each block: eval it first (scnvim <C-e> inside the parens), then put the
// cursor on a number and nudge it with <C-Up>/<C-Down> (<C-S-Up>/<C-S-Down> for
// ×10, or a count like 20<C-Up>). The numbers marked "live" push to SC with no
// recompile — you hear them move; "spec" ones are also clamped to their range.

// 1) Ndef NamedControl defaults  ->  Ndef(\lead).set(\ctl, …)
//    Scrub 440 (live, \freq spec: clamps 20–20000) and 0.1 (live, \amp: 0–1).
(
Ndef(\lead, {
    var sig = VarSaw.ar(\freq.kr(440), 0, 0.4);
    sig * \amp.kr(0.1) ! 2;
}).play;
)

// 2) Pbindef key scalars  ->  Pbindef(\bd, \key, …)
//    Scrub 0.25 (live \dur — no spec, free), 220 (live \freq — clamps).
(
Pbindef(\bd,
    \instrument, \default,
    \dur, 0.25,
    \freq, 220,
    \amp, 0.2,
).play;
)

// 3) Synth-function arg default bound to a var  ->  x.set(\arg, …)
//    Scrub 220 (live \freq — clamps) and 0.1 (live \amp — clamps 0–1).
(
x = { |freq = 220, amp = 0.1|
    SinOsc.ar(freq) * amp ! 2;
}.play;
)

// 4) No handle — a bare {…}.play has nothing to .set, so scrubbing 330 only
//    rewrites the buffer text; re-eval to hear it. (Proves the safe fallback.)
(
{ SinOsc.ar(330) * 0.1 ! 2 }.play;
)

// Clean up:
// Ndef(\lead).clear; Pbindef(\bd).clear; x.free;
