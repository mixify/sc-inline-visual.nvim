-- Render visual annotations using Neovim extmarks with virtual text.

local widgets = require("sc_inline_visual.widgets")

local M = {}

local ns_id = nil
local HL_GROUP = "SCInlineVisual"
local COLUMN_OFFSET = 40 -- virtual text starts after this column

local function ensure_hl()
  vim.api.nvim_set_hl(0, HL_GROUP, { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualBright", { fg = "#aaddff", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualDim", { fg = "#555555", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualEvent", { fg = "#ffaa55", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualSpectrum", { fg = "#77ddaa", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualWave", { fg = "#aa88ff", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualCentroid", { fg = "#ddaa77", default = true })
end

function M.init(bufnr)
  ns_id = vim.api.nvim_create_namespace("sc_inline_visual")
  ensure_hl()
end

function M.clear(bufnr)
  if ns_id and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

--- Pad a text string so it appears at a consistent column
local function pad_to(line_text, target_col)
  local line_len = vim.fn.strdisplaywidth(line_text or "")
  local pad = target_col - line_len
  if pad < 2 then pad = 2 end
  return string.rep(" ", pad)
end

function M.render(bufnr, all_states)
  if not ns_id then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Clear previous extmarks
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, s in pairs(all_states) do
    if not s.active then goto continue end
    -- Build the widget lines for this target
    -- Each widget: label line, then data line
    local vis_lines = {}
    local display_name = s.target:gsub("^scvis_", "")

    -- Header: target name
    vis_lines[#vis_lines + 1] = { text = "╶ " .. display_name, hl = "SCInlineVisualBright" }

    -- Amplitude: meter + sparkline history
    vis_lines[#vis_lines + 1] = { text = "  " .. widgets.meter("amp", s.amp, 1.0) .. " " .. widgets.sparkline("", s.amp_history), hl = HL_GROUP }

    -- Spectrum
    if #s.spectrum > 0 then
      vis_lines[#vis_lines + 1] = { text = "  " .. widgets.spectrum(s.spectrum), hl = "SCInlineVisualSpectrum" }
    end

    -- Waveform
    if #s.waveform > 0 then
      vis_lines[#vis_lines + 1] = { text = "  " .. widgets.waveform(s.waveform), hl = "SCInlineVisualWave" }
    end

    -- Spectral centroid
    if s.centroid > 0 then
      vis_lines[#vis_lines + 1] = { text = "  " .. widgets.centroid(s.centroid), hl = "SCInlineVisualCentroid" }
    end

    -- Parameters
    local param_names = {}
    for name, _ in pairs(s.params) do
      param_names[#param_names + 1] = name
    end
    table.sort(param_names)
    for _, name in ipairs(param_names) do
      vis_lines[#vis_lines + 1] = { text = "  " .. widgets.param_bar(name, s.params[name]), hl = HL_GROUP }
    end

    -- Events
    if #s.events > 0 then
      vis_lines[#vis_lines + 1] = { text = "  " .. widgets.event_timeline(s.events), hl = "SCInlineVisualEvent" }
    end

    -- Place virtual text on buffer lines
    local block_lines = s.end_line - s.start_line + 1
    for i, vl in ipairs(vis_lines) do
      local line_idx = s.start_line + (i - 1)
      if line_idx <= s.end_line and line_idx < #buf_lines then
        local line_text = buf_lines[line_idx + 1] or ""
        local padding = pad_to(line_text, COLUMN_OFFSET)
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
          virt_text = { { padding .. vl.text, vl.hl } },
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      end
    end
    ::continue::
  end
end

return M
