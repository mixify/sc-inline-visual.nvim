-- User-tunable defaults. Mutated in place by M.setup(opts) so other modules
-- can pick up changes by re-reading this table.
return {
  -- UDP port the SC server sends analysis OSC packets to, and Neovim listens on.
  port = 57121,

  -- Render loop / SC analysis rate. Drives both the 1/fps timer interval and
  -- the Impulse.kr rate inside the per-block monitor synths.
  render_fps = 30,

  -- Auto-start on the first `supercollider` filetype. Disable if you prefer
  -- to call :SCInlineVisualStart manually.
  auto_start = true,

  -- Emit vim.notify on start / stop. Set false for a silent setup.
  notify = true,

  -- Idle parent-block GC. After a parent block's monitor has been silent for
  -- this many seconds, the SC bus / router / monitor synths are freed (the
  -- next .play call re-allocates). Set to 0 to disable. ~scvisNdefMap entries
  -- are NOT removed so tid stays stable if the block name recurs.
  idle_gc_seconds = 60,

  -- How often the GC sweep runs (seconds).
  idle_gc_check_seconds = 5,

  -- Pattern visualisation mode for Pbind blocks:
  --   "future"  — preview the next N scheduled events as a forward timeline
  --   "history" — the original sliding window of the last events that played
  --   "both"    — future timeline followed by the recent-history grid
  pattern_view = "future",

  -- How many upcoming events the future timeline previews per evaluation.
  -- Pulled from an independent stream, so stochastic patterns show their
  -- character rather than the exact future. Mirrored into the SC monitor.
  pattern_preview_count = 16,

  -- Inline sparkline for control-rate UGen expressions (LFNoise, SinOsc, …).
  -- A static, source-only simulation of the signal's shape over time, drawn at
  -- the line's end — visible without evaluating. Set false to disable.
  lfo_sparkline = true,

  -- Source-value sliders: for each settable control with a known ControlSpec
  -- (\freq, \amp, \pan, \rq, …) draw a `name value lo ━●━ hi` row, the handle at
  -- the literal in the buffer. Moves the instant you scrub it. Set false to
  -- disable.
  sliders = true,

  -- Keyboard "slider": nudge the number under the cursor and live-push it to SC
  -- (glitch-free `.set` for Ndef NamedControl defaults, Pbindef key values, and
  -- synth-function arg defaults bound to a var `x = { |freq=220| … }.play`;
  -- buffer text always updates so a later eval picks up everything else). Steps
  -- preserve the literal's precision; prefix a count for bigger jumps. Known
  -- ControlSpec names (\freq, \amp, …) clamp the step to their range. Keys are
  -- mapped buffer-locally in supercollider buffers — set any to "" to skip it
  -- and bind <Plug>(ScInlineVisualScrub{Up,Down,BigUp,BigDown}) yourself.
  scrub = {
    enabled = true,
    up = "<C-Up>",
    down = "<C-Down>",
    big_up = "<C-S-Up>",
    big_down = "<C-S-Down>",
  },
}
