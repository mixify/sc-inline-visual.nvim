-- sc-inline-visual.nvim plugin entry point
if vim.g.loaded_sc_inline_visual then return end
vim.g.loaded_sc_inline_visual = 1

vim.api.nvim_create_user_command("SCInlineVisualStart", function()
  require("sc_inline_visual").start()
end, {})

vim.api.nvim_create_user_command("SCInlineVisualStop", function()
  require("sc_inline_visual").stop()
end, {})

vim.api.nvim_create_user_command("SCInlineVisualToggle", function()
  require("sc_inline_visual").toggle()
end, {})

vim.api.nvim_create_user_command("SCInlineVisualRescan", function()
  require("sc_inline_visual").rescan()
end, {})

vim.api.nvim_create_user_command("SCInlineVisualList", function()
  require("sc_inline_visual").list()
end, {})

vim.api.nvim_create_user_command("SCInlineVisualDebug", function()
  local osc = require("sc_inline_visual.osc")
  osc.debug = not osc.debug
  vim.notify("OSC debug: " .. (osc.debug and "ON" or "OFF"))
end, {})

vim.api.nvim_create_user_command("SCInlineVisualTest", function()
  require("sc_inline_visual.osc").send_test()
end, {})

-- Keyboard-slider <Plug> maps. The configured keys (config.scrub) point at
-- these buffer-locally; remap them directly to use your own bindings.
for name, opts in pairs({
  ScInlineVisualScrubUp = { dir = 1 },
  ScInlineVisualScrubDown = { dir = -1 },
  ScInlineVisualScrubBigUp = { dir = 1, big = true },
  ScInlineVisualScrubBigDown = { dir = -1, big = true },
}) do
  vim.keymap.set("n", "<Plug>(" .. name .. ")", function()
    require("sc_inline_visual").scrub(opts)
  end, { silent = true, desc = "SCInlineVisual: scrub number under cursor" })
end

-- Auto-start on .scd files, waiting for scnvim to be ready.
-- Honors require("sc_inline_visual.config").auto_start at the moment the
-- FileType event fires, so users can disable it in their setup() call.
do
  local auto_start_timer = nil
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "supercollider",
    once = true,
    callback = function()
      if not require("sc_inline_visual.config").auto_start then return end
      local sciv = require("sc_inline_visual")
      local attempts = 0
      auto_start_timer = vim.uv.new_timer()
      auto_start_timer:start(1000, 2000, vim.schedule_wrap(function()
        attempts = attempts + 1
        if attempts > 30 then
          auto_start_timer:stop()
          auto_start_timer:close()
          auto_start_timer = nil
          return
        end
        local ok, sclang = pcall(require, "scnvim.sclang")
        if ok and sclang.is_running() then
          auto_start_timer:stop()
          auto_start_timer:close()
          auto_start_timer = nil
          sciv.start()
        end
      end))
    end,
  })
end
