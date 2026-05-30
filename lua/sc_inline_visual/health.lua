-- :checkhealth sc_inline_visual
local M = {}

local function port_in_use(port)
  local udp = vim.uv.new_udp()
  local ok = udp:bind("127.0.0.1", port)
  udp:close()
  return not ok
end

function M.check()
  vim.health.start("sc-inline-visual.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10+ required (this build uses vim.uv)")
  end

  if vim.fn.executable("sclang") == 1 then
    vim.health.ok("sclang on $PATH (" .. vim.fn.exepath("sclang") .. ")")
  else
    vim.health.error(
      "sclang not found on $PATH",
      { "Install SuperCollider: https://supercollider.github.io/downloads" }
    )
  end

  local ok_scnvim = pcall(require, "scnvim.sclang")
  if ok_scnvim then
    local sclang = require("scnvim.sclang")
    if sclang.is_running() then
      vim.health.ok("scnvim loaded; sclang process is running")
    else
      vim.health.warn(
        "scnvim loaded but sclang is not running yet",
        { "Open a .scd buffer and run :SCNvimStart" }
      )
    end
  else
    vim.health.error(
      "scnvim is not installed",
      { 'Add `dependencies = { "davidgranstrom/scnvim" }` to your lazy spec' }
    )
  end

  local config = require("sc_inline_visual.config")
  if port_in_use(config.port) then
    vim.health.warn(
      ("Port %d is already bound"):format(config.port),
      {
        "If the plugin is currently running this is expected.",
        "Otherwise change `port` in setup() to a free port.",
      }
    )
  else
    vim.health.ok(("Port %d is free"):format(config.port))
  end
end

return M
