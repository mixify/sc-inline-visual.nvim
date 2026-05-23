-- sc-inline-visual.nvim plugin entry point

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

-- Auto-start on .scd files, waiting for scnvim to be ready
do
  local auto_start_timer = nil
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "supercollider",
    once = true, -- only set up once
    callback = function()
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
