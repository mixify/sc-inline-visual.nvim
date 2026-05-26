// Load sc/boot.scd before running.
// Each block below should render a braille envelope shape next to the code.

// @vis pluck
Ndef(\pluck, {
    var env = EnvGen.kr(Env.perc(0.005, 0.4), doneAction: 0);
    SinOsc.ar(440) * env * 0.2
}).play;

// @vis pad
Ndef(\pad, {
    var env = EnvGen.kr(Env.adsr(0.4, 0.2, 0.6, 1.2), doneAction: 0);
    Saw.ar([220, 221]) * env * 0.1
}).play;

// @vis swell
Ndef(\swell, {
    var env = EnvGen.kr(Env.linen(0.5, 0.8, 0.5), doneAction: 0);
    PinkNoise.ar() * env * 0.1
}).play;

// @vis shaped
Ndef(\shaped, {
    var env = EnvGen.kr(Env.new([0, 1, 0.3, 0.8, 0], [0.05, 0.2, 0.1, 0.4]), doneAction: 0);
    SinOsc.ar(330) * env * 0.2
}).play;
