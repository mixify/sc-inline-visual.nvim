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

local music = require("sc_inline_visual.music")
local freq_to_note = music.freq_to_note
local fmt_freq = music.fmt_freq

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

--- Envelope preview: render an Env shape as a multi-row braille bar chart.
--- Input: { kind = "perc"|"adsr"|..., points = { {t,v}, ... } }
--- Returns a list of rows (rather than a single row).
function M.env_preview(env)
  if not env or not env.points or #env.points < 2 then return nil end
  local pts = env.points
  local total_t = pts[#pts].t
  if total_t <= 0 then return nil end

  local max_v = 0
  for _, p in ipairs(pts) do
    if math.abs(p.v) > max_v then max_v = math.abs(p.v) end
  end
  if max_v == 0 then max_v = 1 end

  local function level_at(t)
    if t <= pts[1].t then return pts[1].v / max_v end
    for i = 2, #pts do
      if t <= pts[i].t then
        local span = pts[i].t - pts[i - 1].t
        local frac = span > 0 and (t - pts[i - 1].t) / span or 0
        return (pts[i - 1].v + frac * (pts[i].v - pts[i - 1].v)) / max_v
      end
    end
    return pts[#pts].v / max_v
  end

  local WIDTH = 22                  -- chars per row
  local ROWS = 3                    -- braille rows → 12 vertical levels
  local SLOTS = WIDTH * 2
  local V_MAX = ROWS * 4

  -- Per-slot normalized level (0..1)
  local levels = {}
  for i = 0, SLOTS - 1 do
    local t = (i / (SLOTS - 1)) * total_t
    levels[i + 1] = math.max(0, math.min(1, level_at(t)))
  end

  -- Style selection: filled bars for short envelopes (ADSR-like),
  -- thin line plot for waveform-like envelopes (many breakpoints).
  local use_line_plot = #pts >= 10

  -- ── Filled-bar renderer ──
  local function row_chars_bar(r) -- r: 0=top, ROWS-1=bottom
    local offset = (ROWS - 1 - r) * 4
    local chars = {}
    for i = 1, SLOTS, 2 do
      local left = math.max(0, math.min(4, math.floor(levels[i] * V_MAX + 0.5) - offset))
      local right = math.max(0, math.min(4, math.floor(levels[i + 1] * V_MAX + 0.5) - offset))
      local code = 0x2800
      for j = 1, left do code = code + LEFT_DOTS[j] end
      for j = 1, right do code = code + RIGHT_DOTS[j] end
      chars[#chars + 1] = vim.fn.nr2char(code)
    end
    return table.concat(chars)
  end

  -- ── Line-plot renderer (drawille-style; vertically connected) ──
  -- Build a SLOTS × V_MAX boolean pixel grid, then encode each ROW slice.
  local pixels = nil
  local function build_pixels()
    pixels = {}
    for y = 0, V_MAX - 1 do
      pixels[y] = {}
      for x = 1, SLOTS do pixels[y][x] = false end
    end
    local function plot(x, y)
      if y < 0 or y >= V_MAX or x < 1 or x > SLOTS then return end
      pixels[y][x] = true
    end
    local prev_y
    for x = 1, SLOTS do
      -- y=0 at top, V_MAX-1 at bottom; high level → low y
      local y = math.floor((1 - levels[x]) * (V_MAX - 1) + 0.5)
      if prev_y and math.abs(prev_y - y) > 1 then
        local lo, hi = math.min(prev_y, y), math.max(prev_y, y)
        for yy = lo, hi do plot(x, yy) end
      else
        plot(x, y)
      end
      prev_y = y
    end
  end

  local function row_chars_line(r) -- r: 0=top, ROWS-1=bottom
    if not pixels then build_pixels() end
    local chars = {}
    for c = 1, WIDTH do
      local lx, rx = (c - 1) * 2 + 1, (c - 1) * 2 + 2
      local code = 0x2800
      for dot = 0, 3 do                 -- 0=top dot of this row
        local y = r * 4 + dot
        local idx = 4 - dot             -- LEFT_DOTS index (1=bottom, 4=top)
        if pixels[y][lx] then code = code + LEFT_DOTS[idx] end
        if pixels[y][rx] then code = code + RIGHT_DOTS[idx] end
      end
      chars[#chars + 1] = vim.fn.nr2char(code)
    end
    return table.concat(chars)
  end

  local row_chars = use_line_plot and row_chars_line or row_chars_bar

  local ROW_HL = {
    [3] = { "SCInlineVisualAmpHot", "SCInlineVisualAmpHigh", "SCInlineVisualAmpLow" },
    [2] = { "SCInlineVisualAmpHigh", "SCInlineVisualAmpLow" },
    [1] = { "SCInlineVisualAmpMid" },
  }
  local hls = ROW_HL[ROWS] or { "SCInlineVisualAmpMid" }

  local label
  if total_t < 1 then
    label = string.format("%.0fms", total_t * 1000)
  else
    label = string.format("%.2fs", total_t)
  end

  local rows = {}
  for r = 0, ROWS - 1 do
    local row
    if r == 0 then
      row = {
        { "env  ", "SCInlineVisualDim" },
        { row_chars(r), hls[r + 1] or "SCInlineVisualAmpMid" },
        { "  " .. env.kind .. " " .. label, "SCInlineVisualDim" },
      }
    else
      row = {
        { "     ", "SCInlineVisualDim" },
        { row_chars(r), hls[r + 1] or "SCInlineVisualAmpMid" },
      }
    end
    rows[#rows + 1] = row
  end
  return rows
end

--- Pattern preview: render parsed Pbind patterns as visual rows.
--- Returns a list of segment rows.
function M.pattern_preview(params)
  if not params or #params == 0 then return {} end

  local pattern = require("sc_inline_visual.pattern")
  local rows = {}

  -- Separator
  rows[#rows + 1] = { { "  ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌", "SCInlineVisualDim" } }

  for _, p in ipairs(params) do
    local label = string.format("%-5s", p.key:sub(1, 4))

    if p.values then
      if p.key == "dur" then
        -- Rhythm: proportional width blocks
        local total = 0
        for _, v in ipairs(p.values) do total = total + v end
        local WIDTH = 20
        local chars = {}
        for _, v in ipairs(p.values) do
          local w = math.max(1, math.floor(v / total * WIDTH + 0.5))
          if w == 1 then
            chars[#chars + 1] = "▎"
          elseif w == 2 then
            chars[#chars + 1] = "▍▎"
          else
            chars[#chars + 1] = "█" .. string.rep("─", w - 2) .. "▎"
          end
        end
        rows[#rows + 1] = {
          { "  " .. label, "SCInlineVisualDim" },
          { table.concat(chars), "SCInlineVisualAmpMid" },
        }

      elseif p.key == "degree" then
        -- Note names from scale degrees
        local notes = {}
        for _, v in ipairs(p.values) do
          notes[#notes + 1] = pattern.degree_to_note(math.floor(v))
        end
        rows[#rows + 1] = {
          { "  " .. label, "SCInlineVisualDim" },
          { table.concat(notes, " "), "SCInlineVisualHeader" },
        }

      elseif p.key == "midinote" or p.key == "note" then
        -- MIDI note names
        local notes = {}
        for _, v in ipairs(p.values) do
          notes[#notes + 1] = pattern.midi_to_note(math.floor(v))
        end
        rows[#rows + 1] = {
          { "  " .. label, "SCInlineVisualDim" },
          { table.concat(notes, " "), "SCInlineVisualHeader" },
        }

      elseif p.key == "amp" then
        -- Volume per step as block chars
        local chars = {}
        for _, v in ipairs(p.values) do
          local idx = math.floor(math.max(0, math.min(1, v)) * 7) + 1
          chars[#chars + 1] = BLOCK_CHARS[idx]
        end
        rows[#rows + 1] = {
          { "  " .. label, "SCInlineVisualDim" },
          { table.concat(chars, " "), amp_hl(p.values[1] or 0) },
        }

      elseif p.key == "freq" then
        -- Frequencies as note names
        local notes = {}
        for _, v in ipairs(p.values) do
          notes[#notes + 1] = freq_to_note(v)
        end
        rows[#rows + 1] = {
          { "  " .. label, "SCInlineVisualDim" },
          { table.concat(notes, " "), "SCInlineVisualCentroid" },
        }

      else
        -- Generic: show values
        local strs = {}
        for _, v in ipairs(p.values) do
          if v == math.floor(v) then
            strs[#strs + 1] = string.format("%.0f", v)
          else
            strs[#strs + 1] = string.format("%.2g", v)
          end
        end
        rows[#rows + 1] = {
          { "  " .. label, "SCInlineVisualDim" },
          { table.concat(strs, " "), "SCInlineVisual" },
        }
      end

    elseif p.range then
      -- Pwhite range
      rows[#rows + 1] = {
        { "  " .. label, "SCInlineVisualDim" },
        { string.format("~%.2g..%.2g", p.range[1], p.range[2]), "SCInlineVisual" },
      }
    end
  end

  return rows
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
