-- Render visual annotations using Neovim extmarks with virtual text.
-- Compact 2-line display per block with braille density + freq position bar.

local widgets = require("sc_inline_visual.widgets")
local pattern = require("sc_inline_visual.pattern")
local env_parser = require("sc_inline_visual.env")

local M = {}

local ns_id = nil
local buf_cache = {} -- bufnr -> { lines, tick }
local last_rendered = {} -- bufnr -> { target -> { amp, centroid, events_n, params_n, tick } }
local parsed_cache = {} -- bufnr -> { target -> { tick, start_line, end_line, pat_params, env_info } }

-- Sensitivity thresholds; anything smaller is treated as a no-op for redraw.
local AMP_EPSILON = 0.002
local CENTROID_EPSILON = 1.0

local function ensure_hl()
  vim.api.nvim_set_hl(0, "SCInlineVisual", { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualDim", { fg = "#555555", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualEvent", { fg = "#ffaa55", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualCentroid", { fg = "#ddaa77", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualHeader", { fg = "#aaddff", bold = true, default = true })
  -- Amp color gradient: green (quiet) → yellow (moderate) → red (loud)
  vim.api.nvim_set_hl(0, "SCInlineVisualAmpLow", { fg = "#55cc77", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualAmpMid", { fg = "#cccc55", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualAmpHigh", { fg = "#cc5555", default = true })
  vim.api.nvim_set_hl(0, "SCInlineVisualAmpHot", { fg = "#ff3333", bold = true, default = true })
end

function M.init(bufnr)
  ns_id = vim.api.nvim_create_namespace("sc_inline_visual")
  ensure_hl()
end

function M.clear(bufnr)
  if ns_id and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
  buf_cache[bufnr] = nil
  last_rendered[bufnr] = nil
  parsed_cache[bufnr] = nil
end

local function get_buf_lines(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = buf_cache[bufnr]
  if not cached or cached.tick ~= tick then
    buf_cache[bufnr] = {
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
      tick = tick,
    }
  end
  return buf_cache[bufnr].lines
end

local function block_max_width(lines, start_line, end_line)
  local max_w = 0
  for i = start_line + 1, math.min(end_line + 1, #lines) do
    local w = vim.fn.strdisplaywidth(lines[i] or "")
    if w > max_w then max_w = w end
  end
  return max_w
end

local function pad_segments(segments, line_text, col_offset)
  local line_len = vim.fn.strdisplaywidth(line_text or "")
  local pad = col_offset - line_len
  if pad < 2 then pad = 2 end
  local result = { { string.rep(" ", pad), "" } }
  for _, seg in ipairs(segments) do
    result[#result + 1] = seg
  end
  return result
end

function M.render(bufnr, all_states)
  if not ns_id then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local last = last_rendered[bufnr] or {}

  -- Frame-level skip: if every active block has the same (amp, centroid,
  -- events_n, params_n, tick) as the last paint, there's nothing to redraw.
  -- Clearing+rebuilding extmarks at 30 Hz for an idle scene is wasted work.
  local any_dirty = false
  local active_targets = {}
  for _, s in pairs(all_states) do
    if s.active then
      active_targets[s.target] = true
      local prev = last[s.target]
      local params_n = 0
      for _ in pairs(s.params) do
        params_n = params_n + 1
      end
      if
        not prev
        or prev.tick ~= tick
        or prev.events_n ~= #s.events
        or prev.params_n ~= params_n
        or math.abs(prev.amp - s.amp) > AMP_EPSILON
        or math.abs(prev.centroid - s.centroid) > CENTROID_EPSILON
      then
        any_dirty = true
      end
    end
  end
  -- A target disappearing (deactivated or gone) is also dirty so we can wipe it.
  for target in pairs(last) do
    if not active_targets[target] then
      any_dirty = true
      break
    end
  end
  if not any_dirty then return end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  local lines = get_buf_lines(bufnr)
  local new_last = {}
  local pc_buf = parsed_cache[bufnr] or {}
  parsed_cache[bufnr] = pc_buf

  for _, s in pairs(all_states) do
    if not s.active then goto continue end

    local col_offset = block_max_width(lines, s.start_line, s.end_line) + 4

    local vis_rows = widgets.block_vis(s)

    -- Cache Pbind / Env parses by (tick, start_line, end_line) — the parses
    -- only depend on buffer source, not on live audio state.
    local pc = pc_buf[s.target]
    if not pc or pc.tick ~= tick or pc.start_line ~= s.start_line or pc.end_line ~= s.end_line then
      local block_source_lines = {}
      for i = s.start_line + 1, math.min(s.end_line + 1, #lines) do
        block_source_lines[#block_source_lines + 1] = lines[i] or ""
      end
      local block_source = table.concat(block_source_lines, "\n")
      pc = {
        tick = tick,
        start_line = s.start_line,
        end_line = s.end_line,
        pat_params = pattern.parse_pbind(block_source),
        env_info = env_parser.parse(block_source),
      }
      pc_buf[s.target] = pc
    end

    if pc.pat_params then
      for _, row in ipairs(widgets.pattern_preview(pc.pat_params)) do
        vis_rows[#vis_rows + 1] = row
      end
    end
    if pc.env_info then
      local env_rows = widgets.env_preview(pc.env_info)
      if env_rows then
        for _, row in ipairs(env_rows) do
          vis_rows[#vis_rows + 1] = row
        end
      end
    end

    -- Optional: params, events
    local param_names = {}
    for name, _ in pairs(s.params) do
      param_names[#param_names + 1] = name
    end
    table.sort(param_names)
    for _, name in ipairs(param_names) do
      vis_rows[#vis_rows + 1] = widgets.param_bar(name, s.params[name])
    end
    if #s.events > 0 then vis_rows[#vis_rows + 1] = widgets.event_timeline(s.events) end

    -- Place rows on buffer lines, overflow as virt_lines
    local block_len = s.end_line - s.start_line + 1
    for i, row in ipairs(vis_rows) do
      local line_idx = s.start_line + (i - 1)

      if i <= block_len and line_idx < #lines then
        local line_text = lines[line_idx + 1] or ""
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line_idx, 0, {
          virt_text = pad_segments(row, line_text, col_offset),
          virt_text_pos = "eol",
          hl_mode = "combine",
        })
      else
        local overflow_line = math.min(s.end_line, #lines - 1)
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, overflow_line, 0, {
          virt_lines = { pad_segments(row, "", col_offset) },
          virt_lines_above = false,
        })
      end
    end

    do
      local params_n = 0
      for _ in pairs(s.params) do
        params_n = params_n + 1
      end
      new_last[s.target] = {
        amp = s.amp,
        centroid = s.centroid,
        events_n = #s.events,
        params_n = params_n,
        tick = tick,
      }
    end

    ::continue::
  end

  last_rendered[bufnr] = new_last
end

return M
