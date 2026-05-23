// SC Inline Visual — Waveform Shape Demo
// Each block produces a distinct wave shape visible in the inline visualization.
// Run each block with Ctrl-E to see the difference.

// === 1. Pure Sine — smooth hill shape ===
// wave: ⣀⣠⣤⣶⣿⣶⣤⣠⣀⡀⠀⠀⠀⠀⡀⣀
(
{
    SinOsc.ar(100) * 0.3 ! 2;
}.play;
)

// === 2. Sawtooth — rising ramp then drop ===
// wave: ⠀⡀⣀⣠⣤⣴⣶⣾⣿⠀⡀⣀⣠⣤⣴⣶
(
{
    Saw.ar(200) * 0.3 ! 2;
}.play;
)

// === 3. Square/Pulse — flat top, flat bottom ===
// wave: ⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
(
{
    Pulse.ar(100, 0.5) * 0.3 ! 2;
}.play;
)

// === 4. Triangle — zigzag ===
// wave: ⠀⡀⣀⣠⣤⣶⣿⣶⣤⣠⣀⡀⠀⡀⣀⣠
(
{
    LFTri.ar(100) * 0.3 ! 2;
}.play;
)

// === 5. Noise — random static ===
// wave: ⣤⡠⣶⣀⣿⡀⣴⣠⣤⣶⡀⣿⣀⣴⣠⣤
(
{
    WhiteNoise.ar * 0.2 ! 2;
}.play;
)

// === 6. FM — complex moving shape ===
// wave: changes constantly, rich harmonics
(
{
    var mod = SinOsc.ar(300, mul: 400);
    SinOsc.ar(200 + mod) * 0.2 ! 2;
}.play;
)

// === 7. Filtered Saw — spectrum shifts from hi to lo ===
// watch the freq bar slide left as cutoff drops
(
{
    var sig = Saw.ar(80);
    var cutoff = LFSaw.kr(0.2).exprange(200, 8000);
    RLPF.ar(sig, cutoff, 0.3) * 0.3 ! 2;
}.play;
)

// === 8. Blip — varying harmonics, watch spectrum change ===
(
{
    var harm = LFNoise1.kr(0.5).range(1, 30);
    Blip.ar(100, harm) * 0.2 ! 2;
}.play;
)

// === 9. Kick drum — short burst, amp spikes then decays ===
(
{
    var env = EnvGen.kr(Env.perc(0.005, 0.3), Impulse.kr(2), doneAction: 0);
    var sig = SinOsc.ar(60 * (1 + (env * 4))) * env;
    sig * 0.4 ! 2;
}.play;
)

// === 10. Quiet vs Loud — amp difference ===
// try these back to back to see the amp bar change
(
{
    SinOsc.ar(440) * 0.05 ! 2;
}.play;
)

(
{
    SinOsc.ar(440) * 0.5 ! 2;
}.play;
)
