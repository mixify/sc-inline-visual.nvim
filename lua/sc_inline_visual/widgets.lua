-- Small visual widgets rendered as structured segments.
-- Each widget returns a list of {text, hl_group} pairs for multi-color rendering.

local M = {}

local BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local FILLED = "█"
local EMPTY = "░"
local METER_WIDTH = 8

local function block_char(v)
  v = math.max(0, math.min(1, v))
  return BLOCK_CHARS[math.floor(v * 7) + 1]
end

--- Sparkline: history as block characters.
--- Returns segments: { {chars, hl} }
function M.sparkline(history, hl)
  local WIDTH = 16
  local chars = {}
  if #history > 0 then
    local start = math.max(1, #history - (WIDTH - 1))
    for i = start, #history do
      chars[#chars + 1] = block_char(history[i])
    end
  end
  while #chars < WIDTH do
    table.insert(chars, 1, "▁")
  end
  return { { table.concat(chars), hl or "SCInlineVisualDim" } }
end

--- Meter: label + filled bar + empty bar + value.
--- Returns segments with different highlights.
function M.meter(label, value, max_val)
  max_val = max_val or 1.0
  local ratio = math.max(0, math.min(1, value / max_val))
  local filled = math.floor(ratio * METER_WIDTH + 0.5)
  local empty = METER_WIDTH - filled

  return {
    { string.format("%-5s", label), "SCInlineVisualDim" },
    { string.rep(FILLED, filled), "SCInlineVisualBright" },
    { string.rep(EMPTY, empty), "SCInlineVisualDim" },
    { " " .. string.format("%.2f", value), "SCInlineVisual" },
  }
end

--- Centroid sparkline: spectral centroid movement over time.
function M.centroid(value, history)
  local WIDTH = 16
  local MIN_FREQ = 50
  local MAX_FREQ = 10000
  local log_range = math.log(MAX_FREQ / MIN_FREQ)

  local chars = {}
  if history and #history > 0 then
    local start = math.max(1, #history - (WIDTH - 1))
    for i = start, #history do
      local v = history[i]
      if v > MIN_FREQ then
        local ratio = math.log(v / MIN_FREQ) / log_range
        chars[#chars + 1] = block_char(math.max(0, math.min(1, ratio)))
      else
        chars[#chars + 1] = "▁"
      end
    end
  end
  while #chars < WIDTH do
    table.insert(chars, 1, "▁")
  end

  local val_str
  if value >= 1000 then
    val_str = string.format("%.1fk", value / 1000)
  elseif value > 0 then
    val_str = string.format("%.0f", value)
  else
    val_str = "—"
  end

  return {
    { "freq ", "SCInlineVisualDim" },
    { table.concat(chars), "SCInlineVisualCentroid" },
    { "  " .. val_str, "SCInlineVisual" },
  }
end

--- Spectrum: synthetic bell curve from centroid + amp.
function M.spectrum(centroid, amp)
  local WIDTH = 8
  local MIN_FREQ = 50
  local MAX_FREQ = 10000

  if amp < 0.005 then
    return {
      { "spec ", "SCInlineVisualDim" },
      { string.rep("▁", WIDTH), "SCInlineVisualDim" },
      { " lo    hi", "SCInlineVisualDim" },
    }
  end

  local center = 0.5
  if centroid > MIN_FREQ then
    center = math.log(centroid / MIN_FREQ) / math.log(MAX_FREQ / MIN_FREQ)
    center = math.max(0, math.min(1, center))
  end

  local chars = {}
  for i = 1, WIDTH do
    local pos = (i - 0.5) / WIDTH
    local dist = math.abs(pos - center)
    local v = amp * math.exp(-dist * dist * 20)
    chars[#chars + 1] = block_char(v)
  end

  return {
    { "spec ", "SCInlineVisualDim" },
    { table.concat(chars), "SCInlineVisualBright" },
    { " lo    hi", "SCInlineVisualDim" },
  }
end

--- Waveform: rolling sine modulated by amp history.
function M.waveform(amp_history)
  local WIDTH = 16

  if not amp_history or #amp_history == 0 then
    return {
      { "wave ", "SCInlineVisualDim" },
      { string.rep("▄", WIDTH), "SCInlineVisualDim" },
    }
  end

  local t = vim.uv.hrtime() / 1e9
  local chars = {}
  local start = math.max(1, #amp_history - (WIDTH - 1))
  local n = 0
  for i = start, #amp_history do
    local v = amp_history[i] or 0
    local phase = math.sin((n / WIDTH) * math.pi * 4 + t * 8)
    local displaced = 0.5 + (v * 0.45 * phase)
    chars[#chars + 1] = block_char(displaced)
    n = n + 1
  end
  while #chars < WIDTH do
    table.insert(chars, 1, "▄")
  end

  return {
    { "wave ", "SCInlineVisualDim" },
    { table.concat(chars), "SCInlineVisualWave" },
  }
end

--- Parameter bar: label + bar + value.
function M.param_bar(label, value)
  if type(value) ~= "number" then
    return {
      { string.format("%-5s", label:sub(1, 4)), "SCInlineVisualDim" },
      { tostring(value), "SCInlineVisual" },
    }
  end

  local ratio
  if value <= 0 then
    ratio = 0
  elseif value <= 1 then
    ratio = value
  else
    ratio = math.log(value) / math.log(20000)
    ratio = math.max(0, math.min(1, ratio))
  end

  local filled = math.floor(ratio * METER_WIDTH + 0.5)
  local empty = METER_WIDTH - filled

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
    { string.rep(FILLED, filled), "SCInlineVisualBright" },
    { string.rep(EMPTY, empty), "SCInlineVisualDim" },
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
