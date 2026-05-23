-- Small visual widgets rendered as text strings.

local M = {}

local BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local FILLED = "█"
local EMPTY = "░"
local METER_WIDTH = 8

--- Sparkline: history as block characters.
--- e.g. "▄▆██▇▃▁▁▁▁▁▁"
function M.sparkline(name, history)
  local WIDTH = 16
  if #history == 0 then
    local prefix = name ~= "" and (name .. " ") or ""
    return prefix .. string.rep("▁", WIDTH)
  end

  local chars = {}
  local start = math.max(1, #history - (WIDTH - 1))
  for i = start, #history do
    local v = math.max(0, math.min(1, history[i]))
    local idx = math.floor(v * 7) + 1
    chars[#chars + 1] = BLOCK_CHARS[idx]
  end

  while #chars < WIDTH do
    table.insert(chars, 1, "▁")
  end

  local prefix = name ~= "" and (name .. " ") or ""
  return prefix .. table.concat(chars)
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

--- Centroid sparkline: show spectral centroid movement over time.
--- Maps ~50Hz..10000Hz log-scale onto block chars.
--- e.g. "freq ▃▃▄▅▆▇▇▆▅▄▃▃▃▃▃▃  1.8k"
function M.centroid(value, history)
  local WIDTH = 16
  local MIN_FREQ = 50
  local MAX_FREQ = 10000

  local chars = {}
  if history and #history > 0 then
    local start = math.max(1, #history - (WIDTH - 1))
    for i = start, #history do
      local v = history[i]
      if v > MIN_FREQ then
        local ratio = math.log(v / MIN_FREQ) / math.log(MAX_FREQ / MIN_FREQ)
        ratio = math.max(0, math.min(1, ratio))
        local idx = math.floor(ratio * 7) + 1
        chars[#chars + 1] = BLOCK_CHARS[idx]
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

  return "freq " .. table.concat(chars) .. "  " .. val_str
end

--- Spectrum: synthetic spectral shape derived from centroid + amp.
--- Renders a bell curve centered at the centroid frequency position.
--- e.g. "spec ▁▁▃▆█▆▃▁ lo    hi"
function M.spectrum(centroid, amp)
  local WIDTH = 8
  local MIN_FREQ = 50
  local MAX_FREQ = 10000

  if amp < 0.005 then
    return "spec " .. string.rep("▁", WIDTH) .. " lo    hi"
  end

  -- Map centroid to a position 0..1 on log scale
  local center = 0.5
  if centroid > MIN_FREQ then
    center = math.log(centroid / MIN_FREQ) / math.log(MAX_FREQ / MIN_FREQ)
    center = math.max(0, math.min(1, center))
  end

  -- Generate bell curve centered at `center`
  local chars = {}
  for i = 1, WIDTH do
    local pos = (i - 0.5) / WIDTH -- 0..1
    local dist = math.abs(pos - center)
    local v = amp * math.exp(-dist * dist * 20) -- gaussian falloff
    v = math.max(0, math.min(1, v))
    local idx = math.floor(v * 7) + 1
    chars[#chars + 1] = BLOCK_CHARS[idx]
  end

  return "spec " .. table.concat(chars) .. " lo    hi"
end

--- Waveform: amp history displayed as centered oscilloscope.
--- Uses a rolling sine phase so the wave always appears to move.
--- e.g. "wave ▄▅▇▅▄▃▁▃▄▅▇▅▄▃▁▃"
function M.waveform(amp_history)
  local WIDTH = 16

  if not amp_history or #amp_history == 0 then
    return "wave " .. string.rep("▄", WIDTH)
  end

  -- Use real time for continuous phase motion
  local t = vim.uv.hrtime() / 1e9
  local chars = {}
  local start = math.max(1, #amp_history - (WIDTH - 1))
  local n = 0
  for i = start, #amp_history do
    local v = amp_history[i] or 0
    -- Sine wave modulated by amplitude, phase rolls with time
    local phase = math.sin((n / WIDTH) * math.pi * 4 + t * 8)
    local displaced = 0.5 + (v * 0.45 * phase)
    displaced = math.max(0, math.min(1, displaced))
    local idx = math.floor(displaced * 7) + 1
    chars[#chars + 1] = BLOCK_CHARS[idx]
    n = n + 1
  end

  while #chars < WIDTH do
    table.insert(chars, 1, "▄")
  end

  return "wave " .. table.concat(chars)
end

--- Parameter bar: label + bar scaled to a reasonable range + raw value.
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
      local glyphs = { kick = "●", snare = "◆", hat = "·", note = "•" }
      slots[pos] = glyphs[ev.name] or "●"
    end
  end

  return "ev   " .. table.concat(slots)
end

return M
