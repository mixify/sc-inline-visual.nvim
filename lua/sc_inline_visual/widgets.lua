-- Small visual widgets rendered as text strings.

local M = {}

local BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local FILLED = "█"
local EMPTY = "░"
local METER_WIDTH = 8

local EVENT_GLYPHS = {
  kick  = "●",
  snare = "◆",
  hat   = "·",
  note  = "•",
}
local DEFAULT_EVENT_GLYPH = "●"

--- Sparkline: target name + amplitude history as block characters.
--- e.g. "bass ▄▆██▇▃▁"
function M.sparkline(name, history)
  if #history == 0 then
    return name .. " " .. string.rep("▁", 8)
  end

  local chars = {}
  local start = math.max(1, #history - 7)
  for i = start, #history do
    local v = math.max(0, math.min(1, history[i]))
    local idx = math.floor(v * 7) + 1
    chars[#chars + 1] = BLOCK_CHARS[idx]
  end

  while #chars < 8 do
    table.insert(chars, 1, "▁")
  end

  return string.format("%-5s", name) .. table.concat(chars)
end

--- Meter: label + filled/empty bar + numeric value.
--- e.g. "amp  ██████░░ 0.62"
function M.meter(label, value, max_val)
  max_val = max_val or 1.0
  local ratio = math.max(0, math.min(1, value / max_val))
  local filled = math.floor(ratio * METER_WIDTH + 0.5)
  local empty = METER_WIDTH - filled

  return string.format("%-5s", label)
    .. string.rep(FILLED, filled)
    .. string.rep(EMPTY, empty)
    .. " "
    .. string.format("%.2f", value)
end

--- Centroid: show spectral centroid as a position indicator on a frequency scale.
--- Maps ~50Hz..10000Hz log-scale onto a 16-char ruler.
--- e.g. "freq ····▼···········  1840"
function M.centroid(value)
  local WIDTH = 16
  local MIN_FREQ = 50
  local MAX_FREQ = 10000

  local slots = {}
  for i = 1, WIDTH do slots[i] = "·" end

  if value > MIN_FREQ then
    local ratio = math.log(value / MIN_FREQ) / math.log(MAX_FREQ / MIN_FREQ)
    ratio = math.max(0, math.min(1, ratio))
    local pos = math.floor(ratio * (WIDTH - 1)) + 1
    slots[pos] = "▼"
  end

  local val_str
  if value >= 1000 then
    val_str = string.format("%.1fk", value / 1000)
  else
    val_str = string.format("%.0f", value)
  end

  return "freq " .. table.concat(slots) .. "  " .. val_str
end

--- Spectrum: show 8 FFT bin magnitudes as vertical bars.
--- e.g. "spec █▇▅▃▂▁▁▁"
function M.spectrum(bins)
  if not bins or #bins == 0 then
    return "spec " .. string.rep("▁", 8)
  end

  -- Normalize bins to 0..1 range
  local max_val = 0
  for _, v in ipairs(bins) do
    if v > max_val then max_val = v end
  end

  local chars = {}
  for i = 1, math.min(8, #bins) do
    local v = (max_val > 0) and (bins[i] / max_val) or 0
    v = math.max(0, math.min(1, v))
    local idx = math.floor(v * 7) + 1
    chars[#chars + 1] = BLOCK_CHARS[idx]
  end

  -- Pad to 8
  while #chars < 8 do
    chars[#chars + 1] = "▁"
  end

  return "spec " .. table.concat(chars)
end

--- Waveform: show audio samples as a mini oscilloscope.
--- Uses upper/lower block characters to represent bipolar signal (-1..+1).
--- e.g. "wave ▁▃▅▇█▇▅▃▁▃▅▇█▇▅▃"
function M.waveform(samples)
  local WIDTH = 16

  if not samples or #samples == 0 then
    return "wave " .. string.rep("─", WIDTH)
  end

  -- Map bipolar -1..+1 to block chars
  -- ▁ = bottom (-1), █ = top (+1), middle ~= ▄
  local chars = {}
  local step = math.max(1, math.floor(#samples / WIDTH))
  for i = 1, WIDTH do
    local idx = math.min(#samples, (i - 1) * step + 1)
    local v = samples[idx] or 0
    -- Map -1..+1 to 0..1
    local normalized = (v + 1) * 0.5
    normalized = math.max(0, math.min(1, normalized))
    local char_idx = math.floor(normalized * 7) + 1
    chars[#chars + 1] = BLOCK_CHARS[char_idx]
  end

  return "wave " .. table.concat(chars)
end

--- Parameter bar: label + bar scaled to a reasonable range + raw value.
--- e.g. "cut  ███████░ 1200"
function M.param_bar(label, value)
  local ratio
  if type(value) ~= "number" then
    return string.format("%-5s", label:sub(1, 4)) .. tostring(value)
  end

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

  local display_label = label:sub(1, 4)
  local val_str
  if value >= 100 then
    val_str = string.format("%.0f", value)
  elseif value >= 1 then
    val_str = string.format("%.1f", value)
  else
    val_str = string.format("%.2f", value)
  end

  return string.format("%-5s", display_label)
    .. string.rep(FILLED, filled)
    .. string.rep(EMPTY, empty)
    .. " "
    .. val_str
end

--- Event timeline: show recent events as glyphs spread across a time window.
--- e.g. "ev   ●   ●     ●"
function M.event_timeline(events)
  local WIDTH = 16
  local now = vim.uv.hrtime() / 1e9
  local window = 3.0

  local slots = {}
  for i = 1, WIDTH do slots[i] = " " end

  for _, ev in ipairs(events) do
    local age = now - ev.time
    if age < window then
      local pos = math.floor((1 - age / window) * (WIDTH - 1)) + 1
      pos = math.max(1, math.min(WIDTH, pos))
      slots[pos] = EVENT_GLYPHS[ev.name] or DEFAULT_EVENT_GLYPH
    end
  end

  return "ev   " .. table.concat(slots)
end

return M
