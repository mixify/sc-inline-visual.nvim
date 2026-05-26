// Sine-graph envelopes — each block renders a 3-row braille shape next to the code.
// All levels are pre-shifted to [0..1] (sine envelope = 0.5 + 0.5*sin(θ)).
// Load sc/boot.scd before running.

// @vis halfSine
// SC's built-in Env.sine — single half-sine bell curve
Ndef(\halfSine, {
    var env = EnvGen.kr(Env.sine(2, 1), doneAction: 0);
    SinOsc.ar(440) * env * 0.2
}).play;

// @vis oneCycle
// One full cycle, 16 segments over 2s
Ndef(\oneCycle, {
    var env = EnvGen.kr(
        Env.new(
            [0.50, 0.69, 0.85, 0.96, 1.00, 0.96, 0.85, 0.69, 0.50, 0.31, 0.15, 0.04, 0.00, 0.04, 0.15, 0.31, 0.50],
            [0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125, 0.125]
        ),
        doneAction: 0
    );
    SinOsc.ar(440) * env * 0.2
}).play;

// @vis twoCycles
// Two full cycles, 24 segments over 2s
Ndef(\twoCycles, {
    var env = EnvGen.kr(
        Env.new(
            [0.50, 0.75, 0.93, 1.00, 0.93, 0.75, 0.50, 0.25, 0.07, 0.00, 0.07, 0.25, 0.50, 0.75, 0.93, 1.00, 0.93, 0.75, 0.50, 0.25, 0.07, 0.00, 0.07, 0.25, 0.50],
            [0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083, 0.083]
        ),
        doneAction: 0
    );
    SinOsc.ar(440) * env * 0.2
}).play;

// @vis dampedSine
// 3 cycles with linear amplitude decay over 3s
Ndef(\dampedSine, {
    var env = EnvGen.kr(
        Env.new(
            [0.50, 0.77, 0.93, 0.94, 0.81, 0.58, 0.34, 0.18, 0.13, 0.20, 0.37, 0.56, 0.72, 0.79, 0.76, 0.65, 0.50, 0.37, 0.30, 0.30, 0.37, 0.47, 0.56, 0.62, 0.63, 0.59, 0.54, 0.48, 0.46, 0.45, 0.47, 0.49, 0.50],
            [0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094, 0.094]
        ),
        doneAction: 0
    );
    SinOsc.ar(220) * env * 0.2
}).play;

// @vis rampedSine
// 4 cycles modulated by a triangular envelope (swell + fade)
Ndef(\rampedSine, {
    var env = EnvGen.kr(
        Env.new(
            [0.50, 0.52, 0.56, 0.57, 0.50, 0.39, 0.31, 0.35, 0.50, 0.70, 0.81, 0.74, 0.50, 0.21, 0.06, 0.17, 0.50, 0.83, 0.94, 0.79, 0.50, 0.26, 0.19, 0.30, 0.50, 0.65, 0.69, 0.61, 0.50, 0.43, 0.44, 0.48, 0.50],
            [0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078, 0.078]
        ),
        doneAction: 0
    );
    SinOsc.ar(330) * env * 0.2
}).play;
