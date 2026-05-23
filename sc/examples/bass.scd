// Load the visual helper first:
// Execute sc/boot.scd before running this file.

// @vis bass
Ndef(\bass, {
    var cutoff = LFNoise1.kr(1).exprange(200, 4000);
    var sig = Saw.ar(80);
    sig = RLPF.ar(sig, cutoff, 0.2);
    sig * 0.1;
}).play;

Routine({
    loop {
        ~visual.analysis("bass", rrand(0.1, 0.9), rrand(300, 4000));
        ~visual.param("bass", "cutoff", rrand(200, 4000));
        ~visual.event("bass", "note", rrand(0.2, 1.0));
        0.2.wait;
    }
}).play;
