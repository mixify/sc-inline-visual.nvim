// Load the visual helper first:
// Execute sc/boot.scd before running this file.

// @vis drums
Pbind(
    \instrument, \default,
    \dur, Pseq([0.25, 0.25, 0.5, 0.25, 0.25], inf),
    \amp, Pwhite(0.1, 0.8),
    \freq, Pseq([100, 200, 150, 300, 100], inf)
).play;

Routine({
    var patterns = [\kick, \snare, \hat, \kick, \snare];
    loop {
        var which = patterns.choose;
        ~visual.event("drums", which.asString, rrand(0.3, 1.0));
        ~visual.analysis("drums", rrand(0.2, 0.8), rrand(200, 8000));
        rrand(0.1, 0.3).wait;
    }
}).play;
