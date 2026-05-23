-- Render visual annotations using Neovim extmarks with virtual text.
-- Widgets return multi-segment virt_text for per-element highlighting.
-- Uses cached buffer lines, dirty-flag rendering, and virt_lines overflow.

local widgets = require("sc_inline_visual.widgets")

local M = {}

local ns_id = nil
local buf_lines_cache = nil
local buf_lines_tick = -1
local last_render_tick = -1 -- state version counter for dirty checks

local function ensure_hl()
  vim.api.nvim_set_hl(0, "SCInlineVisual", { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualBright", { fg = "#aaddff", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualDim", { fg = "#555555", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualEvent", { fg = "#ffaa55", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualCentroid", { fg = "#ddaa77", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualWave", { fg = "#aa88ff", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualHeader", { fg = "#aaddff", bold = true, default = true })
end

function M.init(bufnr)
  ns_id = vim.api.nvim_create_namespace("sc_inline_visual")
  buf_lines_cache = nil
  buf_lines_tick = -1
  ensure_hl()
end

function M.clear(bufnr)
  if ns_id and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
  buf_lines_cache = nil
  buf_lines_tick = -1
end

--- Get buffer lines, cached by changedtick.
local function get_buf_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if tick ~= buf_lines_tick then
    buf_lines_cache = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    buf_lines_tick = tick
  end
  return buf_lines_cache
end

--- Find the max display width of lines in a block for adaptive column offset.
local function block_max_width(lines, start_line, end_line)
  local max_w = 0
  for i = start_line + 1, math.min(end_line + 1, #lines) do
    local w = vim.fn.strdisplaywidth(lines[i] or "")
    if w > max_w then max_w = w end
  end
  return max_w
end

--- Prepend padding segments to a widget's segments for column alignment.
local function pad_segments(segments, line_text, col_offset)
  local line_len = vim.fn.strdisplaywidth(line_text or "")
  local pad = col_offset - line_len
  if pad < 2 then pad = 2 end
  -- Insert padding as first segment
  local result = { { string.rep(" ", pad), "" } }
  for _, seg in ipairs(segments) do
    result[#result + 1] = seg
  end
  return result
end

function M.render(bufnr, all_states)
  if not ns_id then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = get_buf_lines(bufnr)

  for _, s in pairs(all_states) do
    if not s.active then goto continue end

    -- Adaptive column: max line width in block + 4 padding
    local col_offset = block_max_width(lines, s.start_line, s.end_line) + 4

    -- Build widget rows — each is a list of {text, hl} segments
    local display_name = s.target:gsub("^scvis_", "")
    local rows = {}

    -- Header
    rows[#rows + 1] = { { "╶ " .. display_name, "SCInlineVisualHeader" } }

    -- Amp meter + sparkline
    local amp_row = widgets.meter("amp", s.amp, 1.0)
    -- Append sparkline segments
    amp_row[#amp_row + 1] = { " ", "" }
    for _, seg in ipairs(widgets.sparkline(s.amp_history, "SCInlineVisualBright")) do
      amp_row[#amp_row + 1] = seg
    end
    rows[#rows + 1] = amp_row

    -- Spectrum
    rows[#rows + 1] = widgets.spectrum(s.centroid, s.amp)

    -- Waveform
    rows[#rows + 1] = widgets.waveform(s.amp_history)

    -- Centroid
    if s.centroid > 0 then
      rows[#rows + 1] = widgets.centroid(s.centroid, s.centroid_history)
    end

    -- Params
    local param_names = {}
    for name, _ in pairs(s.params) do
      param_names[#param_names + 1] = name
    end
    table.sort(param_names)
    for _, name in ipairs(param_names) do
      rows[#rows + 1] = widgets.param_bar(name, s.params[name])
    end

    -- Events
    if #s.events > 0 then
      rows[#rows + 1] = widgets.event_timeline(s.events)
    end

    -- Place rows: inline on block lines, overflow as virt_lines below block
    local block_len = s.end_line - s.start_line + 1
    for i, row in ipairs(rows) do
      local line_idx = s.start_line + (i - 1)

      if i <= block_len and line_idx < #lines then
        -- Inline: append as virtual text at end of line
        local line_text = lines[line_idx + 1] or ""
        local padded = pad_segments(row, line_text, col_offset)
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
          virt_text = padded,
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      else
        -- Overflow: place as virt_lines below the last block line
        local overflow_line = math.min(s.end_line, #lines - 1)
        local padded = pad_segments(row, "", col_offset)
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, overflow_line, 0, {
          virt_lines = { padded },
          virt_lines_above = false,
        })
      end
    end

    ::continue::
  end
end

return M
