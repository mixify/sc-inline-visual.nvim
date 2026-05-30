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
}
