-- Minimal OSC UDP receiver using vim.uv
-- Parses OSC messages: /sc/analysis, /sc/event, /sc/param

local M = {}

local udp = nil
local PORT = 57121
M.debug = false

-- Parse a null-terminated OSC string starting at pos.
-- Returns the string and the next position (aligned to 4 bytes).
local function read_osc_string(buf, pos)
  local null_pos = buf:find("\0", pos, true)
  if not null_pos then return nil, pos end
  local s = buf:sub(pos, null_pos - 1)
  -- OSC strings are padded to 4-byte boundary
  local len = null_pos - pos + 1
  local padded = null_pos + 1 + (4 - (len % 4)) % 4
  return s, padded
end

-- Read a big-endian 32-bit float
local function read_float32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  -- IEEE 754 big-endian
  local sign = (b1 >= 128) and -1 or 1
  local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 65536) + (b3 * 256) + b4
  if exp == 0 and mantissa == 0 then return 0, pos + 4 end
  if exp == 255 then return (mantissa == 0) and (sign * math.huge) or (0 / 0), pos + 4 end
  return sign * math.ldexp(1 + mantissa / 8388608, exp - 127), pos + 4
end

-- Read a big-endian 32-bit int
local function read_int32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local val = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  if val >= 2147483648 then val = val - 4294967296 end
  return val, pos + 4
end

-- Parse an OSC message from raw bytes.
-- Returns: address (string), args (list of values)
local function parse_osc(data)
  local addr, pos = read_osc_string(data, 1)
  if not addr then return nil end

  local typetag, next_pos = read_osc_string(data, pos)
  if not typetag or typetag:sub(1, 1) ~= "," then
    return addr, {}
  end

  local args = {}
  pos = next_pos
  for i = 2, #typetag do
    local t = typetag:sub(i, i)
    if t == "f" then
      local val
      val, pos = read_float32(data, pos)
      args[#args + 1] = val
    elseif t == "i" then
      local val
      val, pos = read_int32(data, pos)
      args[#args + 1] = val
    elseif t == "s" then
      local val
      val, pos = read_osc_string(data, pos)
      args[#args + 1] = val or ""
    else
      -- Skip unknown types
      break
    end
  end

  return addr, args
end

function M.start(callback)
  if udp then M.stop() end

  udp = vim.uv.new_udp()
  local ok, err = udp:bind("0.0.0.0", PORT)
  if not ok then
    vim.schedule(function()
      vim.notify("OSC bind failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
    return
  end

  udp:recv_start(function(err, data, addr, flags)
    if err then
      if M.debug then vim.schedule(function() vim.notify("OSC err: " .. tostring(err)) end) end
      return
    end
    if not data then return end

    if M.debug then
      local hex = {}
      for i = 1, math.min(#data, 80) do hex[#hex+1] = string.format("%02x", data:byte(i)) end
      vim.schedule(function()
        vim.notify("OSC raw (" .. #data .. "b): " .. table.concat(hex, " "))
      end)
    end

    local osc_addr, args = parse_osc(data)
    if not osc_addr then return end

    if M.debug then
      local parts = {osc_addr}
      for _, a in ipairs(args) do parts[#parts+1] = tostring(a) end
      vim.schedule(function()
        vim.notify("OSC parsed: " .. table.concat(parts, " | "))
      end)
    end

    if osc_addr == "/sc/analysis" and #args >= 3 then
      -- target, amp, centroid
      vim.schedule(function()
        callback("analysis", args[1], args[2], args[3])
      end)
    elseif osc_addr == "/sc/event" and #args >= 3 then
      -- target, eventName, amp
      vim.schedule(function()
        callback("event", args[1], args[2], args[3])
      end)
    elseif osc_addr == "/sc/param" and #args >= 3 then
      -- target, paramName, value
      vim.schedule(function()
        callback("param", args[1], args[2], args[3])
      end)
    elseif osc_addr == "/sc/waveform" and #args >= 2 then
      local target = args[1]
      local samples = {}
      for i = 2, #args do samples[#samples + 1] = args[i] end
      vim.schedule(function()
        callback("waveform", target, samples)
      end)
    end
  end)
end

function M.stop()
  if udp then
    udp:recv_stop()
    if not udp:is_closing() then
      udp:close()
    end
    udp = nil
  end
end

-- Send a test OSC packet to ourselves (for debugging)
function M.send_test()
  local test_udp = vim.uv.new_udp()
  -- Build OSC message: /sc/analysis ,sff _master <amp> <centroid>
  local function osc_str(s)
    local padded_len = #s + 1
    padded_len = padded_len + (4 - padded_len % 4) % 4
    return s .. string.rep("\0", padded_len - #s)
  end
  local function float32(f)
    -- Pack float as big-endian IEEE 754
    if f == 0 then return "\0\0\0\0" end
    local sign = 0
    if f < 0 then sign = 1; f = -f end
    local m, e = math.frexp(f)
    e = e + 126
    m = (m * 2 - 1) * 8388608
    local b1 = sign * 128 + math.floor(e / 2)
    local b2 = (e % 2) * 128 + math.floor(m / 65536)
    local b3 = math.floor(m / 256) % 256
    local b4 = math.floor(m) % 256
    return string.char(b1, b2, b3, b4)
  end

  local msg = osc_str("/sc/analysis") .. osc_str(",sff") .. osc_str("_master") .. float32(0.65) .. float32(2000)
  test_udp:send(msg, "127.0.0.1", PORT, function()
    test_udp:close()
  end)
end

return M
