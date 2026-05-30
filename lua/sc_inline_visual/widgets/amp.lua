-- The core per-block readout (header + amp braille meter + freq position bar)
-- plus the standalone param bar widget used for arbitrary numeric parameters.

local braille = require("sc_inline_visual.widgets.braille")
local music = require("sc_inline_visual.music")

local braille_pair = braille.braille_pair
local amp_hl = braille.amp_hl
local fmt_freq = music.fmt_freq

local M = {}

--- Braille sparkline with per-character color gradient. Returns multiple
--- {text, hl} segments, each colored by its peak amplitude band.
local function braille_sparkline_colored(values, width)
  width = width or 14
  local n = #values
  local start = math.max(1, n - (width * 2) + 1)
  local vals = {}
  for i = start, n do
    vals[#vals + 1] = values[i]
  end
  while #vals < width * 2 do
    table.insert(vals, 1, 0)
  end

  local segments = {}
  local cur_hl, cur_chars = nil, {}
  for i = 1, #vals - 1, 2 do
    local v1, v2 = vals[i], vals[i + 1]
    local hl = amp_hl(math.max(v1, v2))
    if hl ~= cur_hl then
      if cur_hl and #cur_chars > 0 then
        segments[#segments + 1] = { table.concat(cur_chars), cur_hl }
      end
      cur_hl, cur_chars = hl, {}
    end
    cur_chars[#cur_chars + 1] = braille_pair(v1, v2)
  end
  if cur_hl and #cur_chars > 0 then
    segments[#segments + 1] = { table.concat(cur_chars), cur_hl }
  end

  if #segments == 0 then
    segments[1] = { string.rep(vim.fn.nr2char(0x2800), width), "SCInlineVisualDim" }
  end
  return segments
end

--- Frequency position bar with smoothed centroid + spectral spread region.
--- Centroid is averaged over recent history; spread is the min/max log-position
--- envelope of that history.
local function freq_bar(centroid, centroid_history, width)
  width = width or 14
  local MIN_F, MAX_F = 50, 10000
  local log_range = math.log(MAX_F / MIN_F)

  local function freq_to_pos(f)
    if f <= MIN_F then return 0 end
    return math.max(0, math.min(1, math.log(f / MIN_F) / log_range))
  end

  local smooth_centroid = centroid
  if centroid_history and #centroid_history >= 4 then
    local sum, count = 0, math.min(8, #centroid_history)
    for i = #centroid_history - count + 1, #centroid_history do
      sum = sum + (centroid_history[i] or 0)
    end
    smooth_centroid = sum / count
  end

  local spread = 1
  if centroid_history and #centroid_history >= 4 then
    local count = math.min(12, #centroid_history)
    local min_p, max_p = 1, 0
    for i = #centroid_history - count + 1, #centroid_history do
      local p = freq_to_pos(centroid_history[i] or 0)
      if p < min_p then min_p = p end
      if p > max_p then max_p = p end
    end
    spread = math.max(1, math.floor((max_p - min_p) * width + 0.5))
  end

  local center = freq_to_pos(smooth_centroid)
  local center_slot = math.floor(center * (width - 1)) + 1
  local slots = {}
  for i = 1, width do
    slots[i] = "░"
  end

  local half = math.floor(spread / 2)
  for i = math.max(1, center_slot - half), math.min(width, center_slot + half) do
    slots[i] = "▒"
  end
  if center_slot >= 1 and center_slot <= width then slots[center_slot] = "▓" end

  return table.concat(slots)
end

--- 3-row per-block readout: name header, amp sparkline + value, freq bar + note.
function M.block_vis(state)
  local display_name = state.target:gsub("^scvis_", "")

  local line1 = {
    { "╶ ", "SCInlineVisualDim" },
    { display_name, "SCInlineVisualHeader" },
  }

  local amp_segs = braille_sparkline_colored(state.amp_history, 14)
  local line2 = { { "amp  ", "SCInlineVisualDim" } }
  for _, seg in ipairs(amp_segs) do
    line2[#line2 + 1] = seg
  end
  line2[#line2 + 1] = { "  " .. string.format("%.2f", state.amp), amp_hl(state.amp) }

  local fbar = freq_bar(state.centroid, state.centroid_history, 14)
  local line3 = {
    { "freq ", "SCInlineVisualDim" },
    { fbar, "SCInlineVisualCentroid" },
    { "  " .. fmt_freq(state.centroid), "SCInlineVisual" },
  }

  return { line1, line2, line3 }
end

--- Standalone parameter bar: label + 8-cell ratio bar + value. Non-numeric
--- values are formatted as plain text instead of a bar.
function M.param_bar(label, value)
  if type(value) ~= "number" then
    return {
      { string.format("%-5s", label:sub(1, 4)), "SCInlineVisualDim" },
      { tostring(value), "SCInlineVisual" },
    }
  end

  -- Ratio: linear up to 1, log-scaled toward 20kHz beyond that (frequencies).
  local ratio
  if value <= 0 then
    ratio = 0
  elseif value <= 1 then
    ratio = value
  else
    ratio = math.max(0, math.min(1, math.log(value) / math.log(20000)))
  end

  local filled = math.floor(ratio * 8 + 0.5)
  local empty = 8 - filled

  local val_str
  if value >= 100 then
    val_str = string.format("%.0f", value)
  elseif value >= 1 then
    val_str = string.format("%.1f", value)
  else
    val_str = string.format("%.2f", value)
  end

  return {
    { string.format("%-5s", label:sub(1, 4)), "SCInlineVisualDim" },
    { string.rep("█", filled), "SCInlineVisualAmpMid" },
    { string.rep("░", empty), "SCInlineVisualDim" },
    { " " .. val_str, "SCInlineVisual" },
  }
end

return M
