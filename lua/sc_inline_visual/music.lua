-- Pitch / frequency formatting helpers shared between widgets and pattern.

local M = {}

M.NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

--- MIDI note number (e.g. 69) -> note name with octave (e.g. "A4").
function M.midi_to_note(midi)
  local n = math.floor(midi)
  local name = M.NOTE_NAMES[(n % 12) + 1]
  return name .. (math.floor(n / 12) - 1)
end

--- Frequency in Hz -> nearest note name with cents offset, e.g. 440 -> "A4",
--- 466 -> "A#4+23". Returns "—" for non-positive input.
function M.freq_to_note(hz)
  if hz <= 0 then return "—" end
  -- A4 = MIDI 69 = 440 Hz
  local midi = 69 + 12 * math.log(hz / 440) / math.log(2)
  local n = math.floor(midi + 0.5)
  local cents = math.floor((midi - n) * 100 + 0.5)
  local result = M.NOTE_NAMES[(n % 12) + 1] .. (math.floor(n / 12) - 1)
  if cents > 5 then
    return result .. "+" .. cents
  elseif cents < -5 then
    return result .. cents
  end
  return result
end

--- Frequency -> "<note> <Hz>", e.g. 440 -> "A4 440", 1234 -> "D#6 1.2k".
function M.fmt_freq(hz)
  if hz <= 0 then return "—" end
  local note = M.freq_to_note(hz)
  local rendered = hz >= 1000 and string.format("%.1fk", hz / 1000) or string.format("%.0f", hz)
  return note .. " " .. rendered
end

return M
