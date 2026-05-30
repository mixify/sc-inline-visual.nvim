# sc-inline-visual.nvim

Live, inline visualizations for SuperCollider code in Neovim — amplitude
braille meters, frequency-position bars with note names, and envelope
line-plots rendered as virtual text right next to the block that produced them.

> **Status:** experimental. Tested on macOS with `scsynth` + JACK; API and
> rendering details may change.

## Requirements

- Neovim **≥ 0.10** (uses `vim.uv`)
- [scnvim](https://github.com/davidgranstrom/scnvim) running in the same Neovim
  session (the plugin sends SC code through scnvim's sclang bridge)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with the
  `supercollider` parser installed (`:TSInstall supercollider`) — the buffer
  scanner is tree-sitter based
- SuperCollider (`scsynth` + `sclang`) on `$PATH`

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "mixify/sc-inline-visual.nvim",
  ft = "supercollider",
  dependencies = {
    "davidgranstrom/scnvim",
    "nvim-treesitter/nvim-treesitter",
  },
  opts = {
    -- defaults, all optional
    port                  = 57121,  -- UDP port shared between Neovim and SC
    render_fps            = 30,     -- redraw + SC analysis SendReply rate
    auto_start            = true,   -- start on first .scd buffer
    notify                = true,   -- vim.notify on start / stop
    idle_gc_seconds       = 60,     -- free silent block buses after this idle period (0 = off)
    idle_gc_check_seconds = 5,      -- GC sweep interval
  },
}
```

Then run `:TSInstall supercollider` once to fetch the parser.

The plugin loads on `.scd` filetype and auto-starts after scnvim's sclang
process is up (polls for ~60s, then gives up silently). Set `auto_start = false`
to drive it manually with `:SCInlineVisualStart`.

## Usage

Open any `.scd` file with scnvim running, then evaluate a block (default
scnvim keymap: `<C-e>` on a `( ... )` block). The plugin will:

1. Parse the buffer for evaluatable blocks (`( ... )`, explicit `Ndef`/`Pdef`,
   single-line `{ ... }.play`, or any block tagged with `// @vis <name>`).
2. Rewrite any `<expr>.play` chain so audio is routed through a per-block bus:
   - `{ body }.play` becomes `~scvisWrap.value("block_n", { body }).play`
     (Function dispatch: wraps the body in `Out.ar(bus, ...)`).
   - `Pbind(...).play` and `Pdef(\name, Pbind(...)).play` get the same
     treatment via the Pattern dispatch path
     (`Pbindf(<pattern>, \out, bus)`), so each Pbind streams to its own bus
     and visualizes independently instead of all blending into the master
     readout.
3. Attach an FFT/amplitude monitor synth per block on the SC server.
4. Render virtual-text widgets above each block at ~30 FPS:
   - **amp braille meter** (left-to-right intensity)
   - **frequency position bar** with the dominant note name (e.g. `A4`, `G#5`)
   - **envelope line-plot** for any `EnvGen.kr(Env.new(...))` it can statically
     read out of the block source
   - **pattern preview** for `Pbind`/`Pbindef` blocks, with the currently
     playing step highlighted in real time (each scheduled event sends a
     `/scvis/pat_step` ping back to Neovim) and a `│··│··▲··│··` beat-grid
     row showing where in the pattern you are

Try the bundled examples:

```vim
:edit ~/.local/share/nvim/lazy/sc-inline-visual.nvim/sc/examples/sine_graphs.scd
```

## Commands

| Command                    | Action                                                 |
| -------------------------- | ------------------------------------------------------ |
| `:SCInlineVisualStart`     | Install monitor on SC server, start render loop.       |
| `:SCInlineVisualStop`      | Tear down monitor, clear extmarks.                     |
| `:SCInlineVisualToggle`    | Start if stopped, stop if running.                     |
| `:SCInlineVisualRescan`    | Re-parse the current buffer for blocks.                |
| `:SCInlineVisualList`      | List detected blocks with line ranges.                 |
| `:SCInlineVisualDebug`     | Toggle verbose OSC packet logging.                     |
| `:SCInlineVisualTest`      | Send a synthetic OSC packet (smoke test).              |

Also: `:checkhealth sc_inline_visual` verifies Neovim version, `sclang` on
`$PATH`, scnvim availability, and that the configured port is free.

## How it works

A small SuperCollider script (`sc/monitor.scd`) installs:

- One persistent amp+centroid monitor synth on the master bus.
- `~scvisEnsureBus` — allocates (and caches) the per-block bus / router /
  monitor trio. The router pipes the bus to `out 0` so the user still hears
  it; the monitor runs FFT + Amplitude analysis and reports at `render_fps`.
- `~scvisWrap` — polymorphic decorator. Dispatches on the runtime type of
  the wrapped expression:
  - `Function` → returns `{ Out.ar(bus, SynthDef.wrap(body)) }` (transient
    synth per call, freed by `doneAction` in user UGens).
  - `Pattern`  → returns `Pchain(Pbindf(pattern, \out, bus), Pbind(\scvisStep, Pfunc{...}))`
    so each scheduled Event both writes to the block's bus and pings
    `/scvis/pat_step` over OSC, which lights up the current step in the
    pattern preview.
  - `Event`    → mutates the Event in place (`put(\out, bus)`) and returns
    it; covers the common `(instrument: \name, ...).play` idiom. The
    Pattern and Event clauses both silently override any user-supplied
    `\out` — set it elsewhere if you really need a custom output.
- `~scvisTrackNdef` — alternate path for explicit `Ndef`s, which have their
  own bus on the NodeProxy side; the helper just attaches a monitor synth.

Both monitors emit `SendReply` packets at 30 Hz over OSC (`127.0.0.1:57121`)
that the Neovim side parses and stores per target. A render timer reads that
state and updates extmarks.

`Cmd-.` (or `s.freeAll`) is handled — buses are freed and the monitor
re-installed automatically.

## Marking custom blocks

Add `// @vis <name>` above any region you want tracked under a stable name:

```supercollider
// @vis lead
(
SynthDef(\lead, { |freq = 440| Out.ar(0, SinOsc.ar(freq) * 0.2 ! 2) }).add;
)
```

## Limitations

- A long live-coding session that evaluates many distinct block names will
  accumulate per-block buses; the idle GC (default 60 s, configurable) frees
  them once their monitor has gone silent. The next `.play` on that block
  re-allocates.
- The envelope renderer reads `Env.new([...], [...])` literals — runtime
  values built by Lua-ish expressions don't render.
- The buffer scanner is tree-sitter based, so the `supercollider` parser must
  be installed. Without it the plugin still loads but no blocks are detected.
- Tested with the macOS `scsynth` build over JACK. Other platforms should work
  but are unverified.

## Development

The plugin's SC side lives in `sc/monitor.scd` (install) and
`sc/monitor_free.scd` (teardown); the Lua side loads them with
`vim.fn.readfile`. Edit those files directly when iterating on SC behaviour.

Run the smoke test suite (pure-Lua + UDP loopback, no sclang required):

```sh
bash test/smoke_test.sh
```

The tree-sitter parser tests skip by default. To exercise them locally, build
the SC grammar once and point the test at the resulting `.so`:

```sh
git clone https://github.com/madskjeldgaard/tree-sitter-supercollider /tmp/ts-sc
cc -o /tmp/ts-sc/supercollider.so -shared -fPIC -I /tmp/ts-sc/src \
   /tmp/ts-sc/src/parser.c /tmp/ts-sc/src/scanner.c
SC_TS_PARSER_PATH=/tmp/ts-sc/supercollider.so bash test/smoke_test.sh
```

## License

MIT — see [LICENSE](./LICENSE).
