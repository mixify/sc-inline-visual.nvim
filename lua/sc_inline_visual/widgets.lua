-- Visual widgets using braille characters for dense display.
-- Each widget returns a list of {text, hl_group} segments.

local M = {}

local BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- Braille: 2x4 dot matrix per character (U+2800..U+28FF)
-- Left column dots (bottom to top): 7, 3, 2, 1
-- Right column dots (bottom to top): 8, 6, 5, 4
local LEFT_DOTS  = { 0x40, 0x04, 0x02, 0x01 }
local RIGHT_DOTS = { 0x80, 0x20, 0x10, 0x08 }

--- Pack two values (0..1) into one braille character.
--- Left column = v1 (4 levels), Right column = v2 (4 levels).
local function braille_pair(v1, v2)
  local l = math.floor(math.max(0, math.min(1, v1)) * 4 + 0.5)
  local r = math.floor(math.max(0, math.min(1, v2)) * 4 + 0.5)
  local code = 0x2800
  for i = 1, math.min(l, 4) do code = code + LEFT_DOTS[i] end
  for i = 1, math.min(r, 4) do code = code + RIGHT_DOTS[i] end
  return vim.fn.nr2char(code)
end

--- Single-column braille sparkline (one value per dot column).
local function braille_sparkline(values, width)
  width = width or 12
  local chars = {}
  local n = #values
  -- Pack pairs of consecutive values
  local start = math.max(1, n - (width * 2) + 1)
  local vals = {}
  for i = start, n do vals[#vals + 1] = values[i] end
  -- Pad to even count
  while #vals < width * 2 do table.insert(vals, 1, 0) end

  for i = 1, #vals - 1, 2 do
    chars[#chars + 1] = braille_pair(vals[i], vals[i + 1])
  end
  return table.concat(chars)
end

--- Dual braille sparkline: overlay two histories in one line.
--- Left dots = history1 (e.g. amplitude), Right dots = history2 (e.g. centroid normalized).
local function braille_dual(hist1, hist2, width)
  width = width or 12
  local chars = {}

  -- Normalize hist2 (centroid) to 0..1 via log scale
  local MIN_F, MAX_F = 50, 10000
  local log_range = math.log(MAX_F / MIN_F)
  local function norm_freq(f)
    if f <= MIN_F then return 0 end
    return math.max(0, math.min(1, math.log(f / MIN_F) / log_range))
  end

  -- Take last `width` values from each
  local n1, n2 = #hist1, #hist2
  for i = 1, width do
    local idx1 = n1 - width + i
    local idx2 = n2 - width + i
    local v1 = (idx1 >= 1) and (hist1[idx1] or 0) or 0
    local v2 = (idx2 >= 1) and norm_freq(hist2[idx2] or 0) or 0
    chars[#chars + 1] = braille_pair(v1, v2)
  end
  return table.concat(chars)
end

--- Frequency position bar: shows WHERE the sound is on a lo-hi scale.
--- e.g. "lo░░░▓▓░░hi"
local function freq_position(centroid, width)
  width = width or 10
  local MIN_F, MAX_F = 50, 10000

  local slots = {}
  for i = 1, width do slots[i] = "░" end

  if centroid > MIN_F then
    local ratio = math.log(centroid / MIN_F) / math.log(MAX_F / MIN_F)
    ratio = math.max(0, math.min(1, ratio))
    local pos = math.floor(ratio * (width - 1)) + 1
    -- Fill 2 chars wide for visibility
    slots[pos] = "▓"
    if pos > 1 then slots[pos - 1] = "▒" end
    if pos < width then slots[pos + 1] = "▒" end
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

--- Main visualization: 4-line display per block.
--- Line 1: target name
--- Line 2: amp — braille sparkline + value
--- Line 3: freq — position bar on lo-hi scale + value
--- Line 4: wave — actual waveform shape as braille
--- Returns list of segment rows.
function M.block_vis(state)
  local display_name = state.target:gsub("^scvis_", "")

  -- Line 1: header
  local line1 = {
    { "╶ ", "SCInlineVisualDim" },
    { display_name, "SCInlineVisualHeader" },
  }

  -- Line 2: amp sparkline + value
  local amp_braille = braille_sparkline(state.amp_history, 14)
  local line2 = {
    { "amp  ", "SCInlineVisualDim" },
    { amp_braille, "SCInlineVisualBright" },
    { "  " .. string.format("%.2f", state.amp), "SCInlineVisual" },
  }

  -- Line 3: freq position bar
  local fbar = freq_position(state.centroid, 14)
  local line3 = {
    { "freq ", "SCInlineVisualDim" },
    { fbar, "SCInlineVisualCentroid" },
    { "  " .. fmt_freq(state.centroid), "SCInlineVisual" },
  }

  -- Line 4: waveform
  local line4 = M.waveform(state.waveform)

  return { line1, line2, line3, line4 }
end

--- Waveform: render 32 bipolar audio samples (-1..+1) as braille.
--- Packs two consecutive samples into left/right columns of each braille char.
--- e.g. "wave ⠉⠑⠒⠤⣀⡠⠤⠒⠊⠉⠑⠒⠤⣀⡠⠔"
function M.waveform(samples)
  local WIDTH = 16
  if not samples or #samples < 2 then
    return {
      { "wave ", "SCInlineVisualDim" },
      { string.rep(vim.fn.nr2char(0x2800 + 0x04 + 0x08), WIDTH), "SCInlineVisualDim" }, -- center dots
    }
  end

  -- Normalize samples to 0..1 (from bipolar -1..+1)
  local function norm(v)
    return math.max(0, math.min(1, (v + 1) * 0.5))
  end

  local chars = {}
  local step = math.max(1, math.floor(#samples / (WIDTH * 2)))
  for i = 0, WIDTH - 1 do
    local idx1 = math.min(#samples, i * 2 * step + 1)
    local idx2 = math.min(#samples, (i * 2 + 1) * step + 1)
    chars[#chars + 1] = braille_pair(norm(samples[idx1] or 0), norm(samples[idx2] or 0))
  end

  return {
    { "wave ", "SCInlineVisualDim" },
    { table.concat(chars), "SCInlineVisualWave" },
  }
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
    { string.rep("█", filled), "SCInlineVisualBright" },
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
