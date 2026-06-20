-- Public widget surface. Each widget returns a list of {text, hl_group}
-- segments suitable for `nvim_buf_set_extmark`'s virt_text / virt_lines.

local amp = require("sc_inline_visual.widgets.amp")
local env = require("sc_inline_visual.widgets.env")
local pattern = require("sc_inline_visual.widgets.pattern")

return {
  block_vis = amp.block_vis,
  param_bar = amp.param_bar,
  env_preview = env.env_preview,
  pattern_preview = pattern.pattern_preview,
  pattern_future = pattern.pattern_future,
  event_timeline = pattern.event_timeline,
}
