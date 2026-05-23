-- Visual widgets using braille characters for dense display.
-- Each widget returns a list of {text, hl_group} segments.

local M = {}

local BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- Braille: 2x4 dot matrix per character (U+2800..U+28FF)
local LEFT_DOTS  = { 0x40, 0x04, 0x02, 0x01 }
local RIGHT_DOTS = { 0x80, 0x20, 0x10, 0x08 }

local function braille_pair(v1, v2)
  local l = math.floor(math.max(0, math.min(1, v1)) * 4 + 0.5)
  local r = math.floor(math.max(0, math.min(1, v2)) * 4 + 0.5)
  local code = 0x2800
  for i = 1, math.min(l, 4) do code = code + LEFT_DOTS[i] end
  for i = 1, math.min(r, 4) do code = code + RIGHT_DOTS[i] end
  return vim.fn.nr2char(code)
end

--- Pick highlight group based on amplitude level.
local function amp_hl(v)
  if v >= 0.8 then return "SCInlineVisualAmpHot"
  elseif v >= 0.5 then return "SCInlineVisualAmpHigh"
  elseif v >= 0.2 then return "SCInlineVisualAmpMid"
  else return "SCInlineVisualAmpLow"
  end
end

--- Braille sparkline with per-character color gradient.
--- Returns multiple segments, each colored by amplitude level.
local function braille_sparkline_colored(values, width)
  width = width or 14
  local n = #values
  local start = math.max(1, n - (width * 2) + 1)
  local vals = {}
  for i = start, n do vals[#vals + 1] = values[i] end
  while #vals < width * 2 do table.insert(vals, 1, 0) end

  -- Group consecutive pairs by color
  local segments = {}
  local cur_hl = nil
  local cur_chars = {}
  for i = 1, #vals - 1, 2 do
    local v1, v2 = vals[i], vals[i + 1]
    local peak = math.max(v1, v2)
    local hl = amp_hl(peak)
    if hl ~= cur_hl then
      if cur_hl and #cur_chars > 0 then
        segments[#segments + 1] = { table.concat(cur_chars), cur_hl }
      end
      cur_hl = hl
      cur_chars = {}
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

--- Frequency position bar with smoothed centroid + spectral spread.
--- Uses centroid_history to compute a smoothed position and spread width.
local function freq_bar(centroid, centroid_history, width)
  width = width or 14
  local MIN_F, MAX_F = 50, 10000
  local log_range = math.log(MAX_F / MIN_F)

  local function freq_to_pos(f)
    if f <= MIN_F then return 0 end
    return math.max(0, math.min(1, math.log(f / MIN_F) / log_range))
  end

  -- Smooth centroid: average of recent history
  local smooth_centroid = centroid
  if centroid_history and #centroid_history >= 4 then
    local sum = 0
    local count = math.min(8, #centroid_history)
    for i = #centroid_history - count + 1, #centroid_history do
      sum = sum + (centroid_history[i] or 0)
    end
    smooth_centroid = sum / count
  end

  -- Compute spread from history variance
  local spread = 1 -- default narrow
  if centroid_history and #centroid_history >= 4 then
    local count = math.min(12, #centroid_history)
    local positions = {}
    for i = #centroid_history - count + 1, #centroid_history do
      positions[#positions + 1] = freq_to_pos(centroid_history[i] or 0)
    end
    local min_p, max_p = 1, 0
    for _, p in ipairs(positions) do
      if p < min_p then min_p = p end
      if p > max_p then max_p = p end
    end
    spread = math.max(1, math.floor((max_p - min_p) * width + 0.5))
  end

  local center = freq_to_pos(smooth_centroid)
  local center_slot = math.floor(center * (width - 1)) + 1

  local slots = {}
  for i = 1, width do slots[i] = "░" end

  -- Draw spread region + bright center
  local half = math.floor(spread / 2)
  for i = math.max(1, center_slot - half), math.min(width, center_slot + half) do
    slots[i] = "▒"
  end
  if center_slot >= 1 and center_slot <= width then
    slots[center_slot] = "▓"
  end

  return table.concat(slots)
end

--- Format frequency value for display.
local function fmt_freq(value)
  if value >= 1000 then
    return string.format("%.1fk", value / 1000)
  elseif value > 0 then
    return string.format("%.0f", value)
  end
  return "—"
end

--- Main visualization: 3-line display per block.
function M.block_vis(state)
  local display_name = state.target:gsub("^scvis_", "")

  -- Line 1: header
  local line1 = {
    { "╶ ", "SCInlineVisualDim" },
    { display_name, "SCInlineVisualHeader" },
  }

  -- Line 2: amp — colored braille sparkline + value
  local amp_segs = braille_sparkline_colored(state.amp_history, 14)
  local line2 = { { "amp  ", "SCInlineVisualDim" } }
  for _, seg in ipairs(amp_segs) do
    line2[#line2 + 1] = seg
  end
  line2[#line2 + 1] = { "  " .. string.format("%.2f", state.amp), amp_hl(state.amp) }

  -- Line 3: freq — smoothed position bar with spread
  local fbar = freq_bar(state.centroid, state.centroid_history, 14)
  local line3 = {
    { "freq ", "SCInlineVisualDim" },
    { fbar, "SCInlineVisualCentroid" },
    { "  " .. fmt_freq(state.centroid), "SCInlineVisual" },
  }

  return { line1, line2, line3 }
end

--- Parameter bar: label + filled/empty bar + value.
function M.param_bar(label, value)
  if type(value) ~= "number" then
    return {
      { string.format("%-5s", label:sub(1, 4)), "SCInlineVisualDim" },
      { tostring(value), "SCInlineVisual" },
    }
  end

  local ratio
  if value <= 0 then ratio = 0
  elseif value <= 1 then ratio = value
  else ratio = math.max(0, math.min(1, math.log(value) / math.log(20000)))
  end

  local filled = math.floor(ratio * 8 + 0.5)
  local empty = 8 - filled

  local val_str
  if value >= 100 then val_str = string.format("%.0f", value)
  elseif value >= 1 then val_str = string.format("%.1f", value)
  else val_str = string.format("%.2f", value)
  end

  return {
    { string.format("%-5s", label:sub(1, 4)), "SCInlineVisualDim" },
    { string.rep("█", filled), "SCInlineVisualAmpMid" },
    { string.rep("░", empty), "SCInlineVisualDim" },
    { " " .. val_str, "SCInlineVisual" },
  }
end

--- Event timeline: recent events as glyphs.
function M.event_timeline(events)
  local WIDTH = 16
  local now = vim.uv.hrtime() / 1e9
  local window = 3.0

  local slots = {}
  for i = 1, WIDTH do slots[i] = " " end

  local glyphs = { kick = "●", snare = "◆", hat = "·", note = "•" }
  for _, ev in ipairs(events) do
    local age = now - ev.time
    if age < window then
      local pos = math.floor((1 - age / window) * (WIDTH - 1)) + 1
      pos = math.max(1, math.min(WIDTH, pos))
      slots[pos] = glyphs[ev.name] or "●"
    end
  end

  return {
    { "ev   ", "SCInlineVisualDim" },
    { table.concat(slots), "SCInlineVisualEvent" },
  }
end

return M
