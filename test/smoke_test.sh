#!/usr/bin/env bash
# smoke_test.sh — Comprehensive pipeline validation for sc-inline-visual.nvim
# Tests OSC parsing, UDP receive, state updates, and end-to-end integration
# without requiring SuperCollider or a full Neovim GUI.

set -eo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PLUGIN_DIR/test"
PORT=57199  # Use a non-default port to avoid conflicts
PASS=0
FAIL=0
TOTAL=0

cleanup_pids=()

cleanup() {
  if [ ${#cleanup_pids[@]} -gt 0 ]; then
    for pid in "${cleanup_pids[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
  fi
  rm -f "$TEST_DIR"/_tmp_*.lua "$TEST_DIR"/_tmp_*.py "$TEST_DIR"/_tmp_*.scd "$TEST_DIR"/_tmp_*.txt "$TEST_DIR"/_tmp_*.bin
}
trap cleanup EXIT

report() {
  local name="$1" result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" = "PASS" ]; then
    PASS=$((PASS + 1))
    printf "  [\033[32mPASS\033[0m] %s\n" "$name"
  else
    FAIL=$((FAIL + 1))
    printf "  [\033[31mFAIL\033[0m] %s\n" "$name"
  fi
}

header() {
  printf "\n\033[1m=== %s ===\033[0m\n" "$1"
}

# ─────────────────────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────────────────────
header "Preflight"

if command -v nvim >/dev/null 2>&1; then
  report "nvim found" "PASS"
else
  report "nvim found" "FAIL"
  echo "ERROR: nvim is required. Aborting." >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  report "python3 found" "PASS"
else
  report "python3 found" "FAIL"
  echo "ERROR: python3 is required. Aborting." >&2
  exit 1
fi

if [ -f "$PLUGIN_DIR/lua/sc_inline_visual/osc.lua" ]; then
  report "plugin files exist" "PASS"
else
  report "plugin files exist" "FAIL"
  echo "ERROR: plugin not found at $PLUGIN_DIR" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────
# TEST 1: OSC Parser (pure Lua, no Neovim)
# ─────────────────────────────────────────────────────────────
header "Test 1: OSC Parser"

# We test the parser by extracting the pure-Lua parsing functions
# and running them standalone via nvim --headless (since the parser
# uses no vim APIs aside from the module system).

cat > "$TEST_DIR/_tmp_osc_test.lua" << 'LUAEOF'
-- Standalone test of OSC parsing functions, extracted from osc.lua

local function read_osc_string(buf, pos)
  local null_pos = buf:find("\0", pos, true)
  if not null_pos then return nil, pos end
  local s = buf:sub(pos, null_pos - 1)
  local len = null_pos - pos + 1
  local padded = null_pos + 1 + (4 - (len % 4)) % 4
  return s, padded
end

local function read_float32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local sign = (b1 >= 128) and -1 or 1
  local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 65536) + (b3 * 256) + b4
  if exp == 0 and mantissa == 0 then return 0, pos + 4 end
  if exp == 255 then return (mantissa == 0) and (sign * math.huge) or (0/0), pos + 4 end
  return sign * math.ldexp(1 + mantissa / 8388608, exp - 127), pos + 4
end

local function read_int32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local val = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  if val >= 2147483648 then val = val - 4294967296 end
  return val, pos + 4
end

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
      local val; val, pos = read_float32(data, pos)
      args[#args + 1] = val
    elseif t == "i" then
      local val; val, pos = read_int32(data, pos)
      args[#args + 1] = val
    elseif t == "s" then
      local val; val, pos = read_osc_string(data, pos)
      args[#args + 1] = val or ""
    else
      break
    end
  end
  return addr, args
end

-- Build OSC packet for: /sc/analysis ,sff _master 0.5 2000.0
local function osc_str(s)
  local padded_len = #s + 1
  padded_len = padded_len + (4 - padded_len % 4) % 4
  return s .. string.rep("\0", padded_len - #s)
end

local function float32(f)
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

local errors = {}

-- Test 1a: /sc/analysis ,sff _master 0.5 2000.0
local pkt = osc_str("/sc/analysis") .. osc_str(",sff") .. osc_str("_master") .. float32(0.5) .. float32(2000.0)
local addr, args = parse_osc(pkt)

if addr ~= "/sc/analysis" then
  errors[#errors+1] = "1a: addr=" .. tostring(addr) .. ", expected /sc/analysis"
end
if #args ~= 3 then
  errors[#errors+1] = "1a: #args=" .. #args .. ", expected 3"
end
if type(args[1]) ~= "string" or args[1] ~= "_master" then
  errors[#errors+1] = "1a: args[1]=" .. tostring(args[1]) .. ", expected '_master'"
end
if type(args[2]) ~= "number" or math.abs(args[2] - 0.5) > 0.001 then
  errors[#errors+1] = "1a: args[2]=" .. tostring(args[2]) .. ", expected ~0.5"
end
if type(args[3]) ~= "number" or math.abs(args[3] - 2000.0) > 1.0 then
  errors[#errors+1] = "1a: args[3]=" .. tostring(args[3]) .. ", expected ~2000.0"
end

-- Test 1b: /sc/event ,ssf _master kick 0.8
local pkt2 = osc_str("/sc/event") .. osc_str(",ssf") .. osc_str("_master") .. osc_str("kick") .. float32(0.8)
local addr2, args2 = parse_osc(pkt2)

if addr2 ~= "/sc/event" then
  errors[#errors+1] = "1b: addr=" .. tostring(addr2) .. ", expected /sc/event"
end
if #args2 ~= 3 then
  errors[#errors+1] = "1b: #args=" .. #args2 .. ", expected 3"
end
if args2[1] ~= "_master" then
  errors[#errors+1] = "1b: args[1]=" .. tostring(args2[1]) .. ", expected '_master'"
end
if args2[2] ~= "kick" then
  errors[#errors+1] = "1b: args[2]=" .. tostring(args2[2]) .. ", expected 'kick'"
end
if type(args2[3]) ~= "number" or math.abs(args2[3] - 0.8) > 0.01 then
  errors[#errors+1] = "1b: args[3]=" .. tostring(args2[3]) .. ", expected ~0.8"
end

-- Test 1c: /sc/param ,ssf mysynth freq 440.0
local pkt3 = osc_str("/sc/param") .. osc_str(",ssf") .. osc_str("mysynth") .. osc_str("freq") .. float32(440.0)
local addr3, args3 = parse_osc(pkt3)

if addr3 ~= "/sc/param" then
  errors[#errors+1] = "1c: addr=" .. tostring(addr3) .. ", expected /sc/param"
end
if args3[1] ~= "mysynth" then
  errors[#errors+1] = "1c: args[1]=" .. tostring(args3[1]) .. ", expected 'mysynth'"
end
if args3[2] ~= "freq" then
  errors[#errors+1] = "1c: args[2]=" .. tostring(args3[2]) .. ", expected 'freq'"
end
if type(args3[3]) ~= "number" or math.abs(args3[3] - 440.0) > 0.5 then
  errors[#errors+1] = "1c: args[3]=" .. tostring(args3[3]) .. ", expected ~440.0"
end

-- Test 1d: edge case — zero float
local pkt4 = osc_str("/sc/analysis") .. osc_str(",sff") .. osc_str("zero") .. float32(0) .. float32(0)
local addr4, args4 = parse_osc(pkt4)
if args4[2] ~= 0 then
  errors[#errors+1] = "1d: args[2]=" .. tostring(args4[2]) .. ", expected 0"
end
if args4[3] ~= 0 then
  errors[#errors+1] = "1d: args[3]=" .. tostring(args4[3]) .. ", expected 0"
end

-- Test 1e: int32 parsing
local function int32(n)
  if n < 0 then n = n + 4294967296 end
  local b1 = math.floor(n / 16777216) % 256
  local b2 = math.floor(n / 65536) % 256
  local b3 = math.floor(n / 256) % 256
  local b4 = n % 256
  return string.char(b1, b2, b3, b4)
end

local pkt5 = osc_str("/test") .. osc_str(",i") .. int32(42)
local addr5, args5 = parse_osc(pkt5)
if addr5 ~= "/test" then
  errors[#errors+1] = "1e: addr=" .. tostring(addr5) .. ", expected /test"
end
if args5[1] ~= 42 then
  errors[#errors+1] = "1e: args[1]=" .. tostring(args5[1]) .. ", expected 42"
end

-- Test 1f: negative int32
local pkt6 = osc_str("/test") .. osc_str(",i") .. int32(-1)
local _, args6 = parse_osc(pkt6)
if args6[1] ~= -1 then
  errors[#errors+1] = "1f: args[1]=" .. tostring(args6[1]) .. ", expected -1"
end

-- Output results
if #errors == 0 then
  print("OSC_PARSER_RESULT:PASS")
else
  for _, e in ipairs(errors) do
    io.stderr:write("  OSC parser error: " .. e .. "\n")
  end
  print("OSC_PARSER_RESULT:FAIL")
end
LUAEOF

OSC_RESULT=$(nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_osc_test.lua" \
  -c "qa!" 2>&1 | grep "OSC_PARSER_RESULT:" | head -1 || true)

if [[ "$OSC_RESULT" == *":PASS"* ]]; then
  report "OSC parser: /sc/analysis ,sff _master 0.5 2000.0" "PASS"
  report "OSC parser: /sc/event ,ssf" "PASS"
  report "OSC parser: /sc/param ,ssf" "PASS"
  report "OSC parser: zero float edge case" "PASS"
  report "OSC parser: int32 positive" "PASS"
  report "OSC parser: int32 negative" "PASS"
else
  # Run again to capture stderr for diagnostics
  nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_osc_test.lua" \
    -c "qa!" 2>&1 | { grep -v "^$" || true; } | head -20 >&2
  report "OSC parser tests" "FAIL"
fi

# ─────────────────────────────────────────────────────────────
# TEST 1b: Cross-validate with Python-built OSC packets
# ─────────────────────────────────────────────────────────────
header "Test 1b: Python-built OSC packets parsed by Lua"

cat > "$TEST_DIR/_tmp_build_osc.py" << 'PYEOF'
import struct, sys

def osc_string(s):
    """Encode a string as an OSC string (null-terminated, 4-byte aligned)."""
    encoded = s.encode('ascii') + b'\x00'
    # Pad to 4-byte boundary
    padding = (4 - len(encoded) % 4) % 4
    return encoded + b'\x00' * padding

def osc_float(f):
    return struct.pack('>f', f)

def osc_int(i):
    return struct.pack('>i', i)

# Build: /sc/analysis ,sff _master 0.5 2000.0
msg = osc_string('/sc/analysis') + osc_string(',sff') + osc_string('_master') + osc_float(0.5) + osc_float(2000.0)

# Write raw bytes to file
with open(sys.argv[1], 'wb') as f:
    f.write(msg)

# Also build /sc/event ,ssf _master kick 0.8
msg2 = osc_string('/sc/event') + osc_string(',ssf') + osc_string('_master') + osc_string('kick') + osc_float(0.8)
with open(sys.argv[2], 'wb') as f:
    f.write(msg2)

print("PYTHON_BUILD:OK")
PYEOF

PY_BUILD=$(python3 "$TEST_DIR/_tmp_build_osc.py" \
  "$TEST_DIR/_tmp_osc_pkt1.bin" \
  "$TEST_DIR/_tmp_osc_pkt2.bin" 2>&1)

if [[ "$PY_BUILD" == *"OK"* ]]; then
  report "Python OSC packet builder" "PASS"
else
  report "Python OSC packet builder" "FAIL"
  echo "$PY_BUILD" >&2
fi

# Now parse the Python-built packets in Lua
cat > "$TEST_DIR/_tmp_osc_crossval.lua" << 'LUAEOF'
-- Same parser functions as above
local function read_osc_string(buf, pos)
  local null_pos = buf:find("\0", pos, true)
  if not null_pos then return nil, pos end
  local s = buf:sub(pos, null_pos - 1)
  local len = null_pos - pos + 1
  local padded = null_pos + 1 + (4 - (len % 4)) % 4
  return s, padded
end

local function read_float32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local sign = (b1 >= 128) and -1 or 1
  local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 65536) + (b3 * 256) + b4
  if exp == 0 and mantissa == 0 then return 0, pos + 4 end
  if exp == 255 then return (mantissa == 0) and (sign * math.huge) or (0/0), pos + 4 end
  return sign * math.ldexp(1 + mantissa / 8388608, exp - 127), pos + 4
end

local function read_int32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local val = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
  if val >= 2147483648 then val = val - 4294967296 end
  return val, pos + 4
end

local function parse_osc(data)
  local addr, pos = read_osc_string(data, 1)
  if not addr then return nil end
  local typetag, next_pos = read_osc_string(data, pos)
  if not typetag or typetag:sub(1,1) ~= "," then return addr, {} end
  local args = {}
  pos = next_pos
  for i = 2, #typetag do
    local t = typetag:sub(i,i)
    if t == "f" then
      local val; val, pos = read_float32(data, pos); args[#args+1] = val
    elseif t == "i" then
      local val; val, pos = read_int32(data, pos); args[#args+1] = val
    elseif t == "s" then
      local val; val, pos = read_osc_string(data, pos); args[#args+1] = val or ""
    else break end
  end
  return addr, args
end

local test_dir = vim.env.TEST_DIR or "."
local errors = {}

-- Read packet 1
local f1 = io.open(test_dir .. "/_tmp_osc_pkt1.bin", "rb")
if f1 then
  local data = f1:read("*a"); f1:close()
  local addr, args = parse_osc(data)
  if addr ~= "/sc/analysis" then errors[#errors+1] = "pkt1 addr=" .. tostring(addr) end
  if args[1] ~= "_master" then errors[#errors+1] = "pkt1 args[1]=" .. tostring(args[1]) end
  if math.abs((args[2] or 0) - 0.5) > 0.001 then errors[#errors+1] = "pkt1 args[2]=" .. tostring(args[2]) end
  if math.abs((args[3] or 0) - 2000.0) > 1.0 then errors[#errors+1] = "pkt1 args[3]=" .. tostring(args[3]) end
else
  errors[#errors+1] = "cannot open pkt1"
end

-- Read packet 2
local f2 = io.open(test_dir .. "/_tmp_osc_pkt2.bin", "rb")
if f2 then
  local data = f2:read("*a"); f2:close()
  local addr, args = parse_osc(data)
  if addr ~= "/sc/event" then errors[#errors+1] = "pkt2 addr=" .. tostring(addr) end
  if args[1] ~= "_master" then errors[#errors+1] = "pkt2 args[1]=" .. tostring(args[1]) end
  if args[2] ~= "kick" then errors[#errors+1] = "pkt2 args[2]=" .. tostring(args[2]) end
  if math.abs((args[3] or 0) - 0.8) > 0.01 then errors[#errors+1] = "pkt2 args[3]=" .. tostring(args[3]) end
else
  errors[#errors+1] = "cannot open pkt2"
end

if #errors == 0 then
  print("CROSSVAL_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  crossval error: " .. e .. "\n") end
  print("CROSSVAL_RESULT:FAIL")
end
LUAEOF

CROSSVAL_RESULT=$(TEST_DIR="$TEST_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_osc_crossval.lua" \
  -c "qa!" 2>&1 | grep "CROSSVAL_RESULT:" | head -1 || true)

if [[ "$CROSSVAL_RESULT" == *":PASS"* ]]; then
  report "Python-built packets parsed by Lua parser" "PASS"
else
  report "Python-built packets parsed by Lua parser" "FAIL"
fi

rm -f "$TEST_DIR/_tmp_osc_pkt1.bin" "$TEST_DIR/_tmp_osc_pkt2.bin"

# ─────────────────────────────────────────────────────────────
# TEST 2: UDP Receive (headless nvim + Python sender)
# ─────────────────────────────────────────────────────────────
header "Test 2: UDP Receive"

UDP_RESULT_FILE="$TEST_DIR/_tmp_udp_result.txt"
rm -f "$UDP_RESULT_FILE"

cat > "$TEST_DIR/_tmp_udp_receiver.lua" << LUAEOF
-- Start a UDP listener using vim.uv, write received data to a file.
local port = $PORT
local result_file = "$UDP_RESULT_FILE"

-- Inline OSC parser (same as in osc.lua)
local function read_osc_string(buf, pos)
  local null_pos = buf:find("\0", pos, true)
  if not null_pos then return nil, pos end
  local s = buf:sub(pos, null_pos - 1)
  local len = null_pos - pos + 1
  local padded = null_pos + 1 + (4 - (len % 4)) % 4
  return s, padded
end

local function read_float32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local sign = (b1 >= 128) and -1 or 1
  local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 65536) + (b3 * 256) + b4
  if exp == 0 and mantissa == 0 then return 0, pos + 4 end
  if exp == 255 then return (mantissa == 0) and (sign * math.huge) or (0/0), pos + 4 end
  return sign * math.ldexp(1 + mantissa / 8388608, exp - 127), pos + 4
end

local function parse_osc(data)
  local addr, pos = read_osc_string(data, 1)
  if not addr then return nil end
  local typetag, next_pos = read_osc_string(data, pos)
  if not typetag or typetag:sub(1,1) ~= "," then return addr, {} end
  local args = {}
  pos = next_pos
  for i = 2, #typetag do
    local t = typetag:sub(i,i)
    if t == "f" then
      local val; val, pos = read_float32(data, pos); args[#args+1] = val
    elseif t == "s" then
      local val; val, pos = read_osc_string(data, pos); args[#args+1] = val or ""
    else break end
  end
  return addr, args
end

local udp = vim.uv.new_udp()
local ok, err = udp:bind("0.0.0.0", port)
if not ok then
  local f = io.open(result_file, "w")
  f:write("BIND_FAILED:" .. tostring(err))
  f:close()
  vim.cmd("qa!")
  return
end

local received_count = 0
local results = {}

udp:recv_start(function(err_recv, data, addr, flags)
  if err_recv or not data then return end
  received_count = received_count + 1
  local osc_addr, args = parse_osc(data)
  if osc_addr then
    local parts = {osc_addr}
    for _, a in ipairs(args) do parts[#parts+1] = tostring(a) end
    results[#results+1] = table.concat(parts, "|")
  end

  if received_count >= 3 then
    vim.schedule(function()
      udp:recv_stop()
      if not udp:is_closing() then udp:close() end
      local f = io.open(result_file, "w")
      f:write("RECEIVED:" .. received_count .. "\n")
      for _, r in ipairs(results) do f:write(r .. "\n") end
      f:close()
      vim.cmd("qa!")
    end)
  end
end)

-- Timeout after 8 seconds
local timeout = vim.uv.new_timer()
timeout:start(8000, 0, vim.schedule_wrap(function()
  udp:recv_stop()
  if not udp:is_closing() then udp:close() end
  local f = io.open(result_file, "w")
  f:write("TIMEOUT:received=" .. received_count .. "\n")
  for _, r in ipairs(results) do f:write(r .. "\n") end
  f:close()
  vim.cmd("qa!")
end))
LUAEOF

cat > "$TEST_DIR/_tmp_udp_sender.py" << PYEOF
import socket, struct, time, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 57199

def osc_string(s):
    encoded = s.encode('ascii') + b'\x00'
    padding = (4 - len(encoded) % 4) % 4
    return encoded + b'\x00' * padding

def osc_float(f):
    return struct.pack('>f', f)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# Wait for nvim to start up and bind
time.sleep(2)

# Send 3 packets
msgs = [
    osc_string('/sc/analysis') + osc_string(',sff') + osc_string('_master') + osc_float(0.5) + osc_float(2000.0),
    osc_string('/sc/analysis') + osc_string(',sff') + osc_string('_master') + osc_float(0.7) + osc_float(3000.0),
    osc_string('/sc/analysis') + osc_string(',sff') + osc_string('_master') + osc_float(0.3) + osc_float(1000.0),
]

for msg in msgs:
    sock.sendto(msg, ('127.0.0.1', PORT))
    time.sleep(0.1)

sock.close()
print("SENT:3")
PYEOF

# Start nvim receiver in background
nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_udp_receiver.lua" &
NVM_PID=$!
cleanup_pids+=($NVM_PID)

# Start Python sender
python3 "$TEST_DIR/_tmp_udp_sender.py" "$PORT" >/dev/null 2>&1

# Wait for nvim to finish (it should quit after receiving 3 packets or timeout)
wait $NVM_PID 2>/dev/null || true
cleanup_pids=("${cleanup_pids[@]/$NVM_PID/}")

if [ -f "$UDP_RESULT_FILE" ]; then
  UDP_CONTENT=$(cat "$UDP_RESULT_FILE")
  if echo "$UDP_CONTENT" | grep -q "RECEIVED:3"; then
    report "UDP receive: 3 packets arrived" "PASS"
    # Check content of first parsed message
    if echo "$UDP_CONTENT" | grep -q "/sc/analysis|_master|0.5"; then
      report "UDP receive: OSC content correct" "PASS"
    else
      report "UDP receive: OSC content correct" "FAIL"
      echo "  Got: $UDP_CONTENT" >&2
    fi
  elif echo "$UDP_CONTENT" | grep -q "BIND_FAILED"; then
    report "UDP receive: bind to port $PORT" "FAIL"
    echo "  $UDP_CONTENT" >&2
    report "UDP receive: OSC content correct" "FAIL"
  elif echo "$UDP_CONTENT" | grep -q "TIMEOUT"; then
    # Check if any arrived
    if echo "$UDP_CONTENT" | grep -q "received=0"; then
      report "UDP receive: packets arrived" "FAIL"
      echo "  Timed out with 0 packets received" >&2
    else
      report "UDP receive: partial receive" "FAIL"
      echo "  $UDP_CONTENT" >&2
    fi
    report "UDP receive: OSC content correct" "FAIL"
  else
    report "UDP receive: unexpected output" "FAIL"
    echo "  $UDP_CONTENT" >&2
  fi
else
  report "UDP receive: result file created" "FAIL"
  echo "  $UDP_RESULT_FILE was not created" >&2
fi

# ─────────────────────────────────────────────────────────────
# TEST 3: State Update (_master target broadcasts to active blocks)
# ─────────────────────────────────────────────────────────────
header "Test 3: State Update"

cat > "$TEST_DIR/_tmp_state_test.lua" << 'LUAEOF'
-- Test state management in isolation.
-- We need to set up enough vim environment that state.lua works (it uses vim.uv.hrtime).

package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path

local state = require("sc_inline_visual.state")
local errors = {}

-- Create mock blocks (as parser.scan would return)
-- synth1/synth2 are anonymous, bass is an ndef
local blocks = {
  { target = "synth1", kind = "anonymous", start_line = 0, end_line = 5 },
  { target = "synth2", kind = "anonymous", start_line = 7, end_line = 12 },
  { target = "pad",    kind = "anonymous", start_line = 14, end_line = 20 },
  { target = "bass",   kind = "ndef",      start_line = 22, end_line = 28 },
}

state.init(blocks)

-- 3a: Initially no blocks are active
local all = state.get_all()
local any_active = false
for _, s in pairs(all) do
  if s.active then any_active = true end
end
if any_active then
  errors[#errors+1] = "3a: blocks should start inactive"
end

-- 3b: Activate synth1 and synth2 (both anonymous)
state.activate("synth1")
state.activate("synth2")
all = state.get_all()
if not all["synth1"].active then errors[#errors+1] = "3b: synth1 should be active" end
if not all["synth2"].active then errors[#errors+1] = "3b: synth2 should be active" end
if all["pad"].active then errors[#errors+1] = "3b: pad should be inactive" end

-- 3c: _master update should go to ALL active anonymous blocks
state.update("analysis", "_master", 0.5, 2000.0)
all = state.get_all()
if math.abs(all["synth1"].amp - 0.5) > 0.001 then
  errors[#errors+1] = "3c: synth1.amp=" .. all["synth1"].amp .. ", expected 0.5"
end
if math.abs(all["synth2"].amp - 0.5) > 0.001 then
  errors[#errors+1] = "3c: synth2.amp=" .. all["synth2"].amp .. ", expected 0.5"
end
-- pad is inactive — should NOT get _master data
if all["pad"].amp ~= 0 then
  errors[#errors+1] = "3c: pad.amp=" .. all["pad"].amp .. ", expected 0 (inactive)"
end
-- bass is ndef kind, not anonymous — should NOT get _master data
if all["bass"].amp ~= 0 then
  errors[#errors+1] = "3c: bass.amp=" .. all["bass"].amp .. ", expected 0 (ndef, not anon)"
end

-- 3c2: Named target (ndef) should get direct updates, not _master
state.update("analysis", "bass", 0.9, 4000.0)
all = state.get_all()
if math.abs(all["bass"].amp - 0.9) > 0.001 then
  errors[#errors+1] = "3c2: bass.amp=" .. all["bass"].amp .. ", expected 0.9"
end

-- 3c3: After new _master update, all active blocks without `monitored` get updated.
-- bass was never marked monitored, so it also receives _master.
state.update("analysis", "_master", 0.7, 3000.0)
all = state.get_all()
if math.abs(all["synth1"].amp - 0.7) > 0.001 then
  errors[#errors+1] = "3c3: synth1.amp=" .. all["synth1"].amp .. ", expected 0.7"
end
if math.abs(all["synth2"].amp - 0.7) > 0.001 then
  errors[#errors+1] = "3c3: synth2.amp=" .. all["synth2"].amp .. ", expected 0.7"
end
-- bass also gets _master since monitored is false (mark_wrapped was not called)
if math.abs(all["bass"].amp - 0.7) > 0.001 then
  errors[#errors+1] = "3c3: bass.amp=" .. all["bass"].amp .. ", expected 0.7 (_master reaches it)"
end

-- 3d: Centroid should reflect latest _master update (3000 from 3c3)
if math.abs(all["synth1"].centroid - 3000.0) > 1.0 then
  errors[#errors+1] = "3d: synth1.centroid=" .. all["synth1"].centroid
end

-- 3e: amp_history should have two entries (from 3c and 3c3 _master updates)
if #all["synth1"].amp_history ~= 2 then
  errors[#errors+1] = "3e: synth1 history len=" .. #all["synth1"].amp_history .. ", expected 2"
end

-- 3f: Direct target update should auto-activate
state.update("analysis", "pad", 0.9, 500.0)
all = state.get_all()
if not all["pad"].active then
  errors[#errors+1] = "3f: pad should be active after direct update"
end
if math.abs(all["pad"].amp - 0.9) > 0.01 then
  errors[#errors+1] = "3f: pad.amp=" .. all["pad"].amp .. ", expected 0.9"
end

-- 3g: Event update
state.update("event", "synth1", "kick", 0.8)
all = state.get_all()
if #all["synth1"].events ~= 1 then
  errors[#errors+1] = "3g: synth1 events=" .. #all["synth1"].events .. ", expected 1"
end
if all["synth1"].events[1].name ~= "kick" then
  errors[#errors+1] = "3g: event name=" .. tostring(all["synth1"].events[1].name)
end

-- 3h: Param update
state.update("param", "synth1", "freq", 440.0)
all = state.get_all()
if all["synth1"].params["freq"] ~= 440.0 then
  errors[#errors+1] = "3h: synth1.params.freq=" .. tostring(all["synth1"].params["freq"])
end

-- 3i: Deactivate all
state.deactivate_all()
all = state.get_all()
for name, s in pairs(all) do
  if s.active then
    errors[#errors+1] = "3i: " .. name .. " should be inactive after deactivate_all"
  end
end

-- 3j: activate_by_line
state.init(blocks)
local found = state.activate_by_line(3) -- within synth1 (0-5)
all = state.get_all()
if found ~= "synth1" then
  errors[#errors+1] = "3j: activate_by_line(3) found=" .. tostring(found) .. ", expected synth1"
end
if not all["synth1"].active then
  errors[#errors+1] = "3j: synth1 should be active"
end

-- 3k: bump_step advances current_step counter
state.init(blocks)
if all["synth1"].current_step ~= -1 then
  errors[#errors+1] = "3k: initial current_step=" .. tostring(all["synth1"].current_step) .. ", expected -1"
end
state.bump_step("synth1")
state.bump_step("synth1")
state.bump_step("synth1")
all = state.get_all()
if all["synth1"].current_step ~= 2 then
  errors[#errors+1] = "3k: after 3 bumps current_step=" .. tostring(all["synth1"].current_step) .. ", expected 2"
end
if not all["synth1"].active then
  errors[#errors+1] = "3k: bump_step should activate the block"
end

-- 3l: bump_step on unknown target is a no-op
state.bump_step("nonexistent")  -- should not error

-- 3m: reset clears everything
state.reset()
all = state.get_all()
local count = 0
for _ in pairs(all) do count = count + 1 end
if count ~= 0 then
  errors[#errors+1] = "3m: after reset, state count=" .. count .. ", expected 0"
end

if #errors == 0 then
  print("STATE_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  state error: " .. e .. "\n") end
  print("STATE_RESULT:FAIL")
end
LUAEOF

STATE_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_state_test.lua" \
  -c "qa!" 2>&1 | grep "STATE_RESULT:" | head -1 || true)

if [[ "$STATE_RESULT" == *":PASS"* ]]; then
  report "State: blocks start inactive" "PASS"
  report "State: activate specific targets" "PASS"
  report "State: _master broadcasts to active blocks only" "PASS"
  report "State: centroid updated" "PASS"
  report "State: amp_history tracked" "PASS"
  report "State: direct target auto-activates" "PASS"
  report "State: event update" "PASS"
  report "State: param update" "PASS"
  report "State: deactivate_all" "PASS"
  report "State: activate_by_line" "PASS"
  report "State: bump_step advances current_step + activates" "PASS"
  report "State: reset clears state" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_state_test.lua" \
    -c "qa!" 2>&1 | head -20 >&2
  report "State tests" "FAIL"
fi

# ─────────────────────────────────────────────────────────────
# TEST 4: End-to-end Integration
# ─────────────────────────────────────────────────────────────
header "Test 4: End-to-End Integration"

# Create a test .scd file with @vis blocks
cat > "$TEST_DIR/_tmp_test.scd" << 'SCDEOF'
// @vis test
(
Ndef(\test, {
    SinOsc.ar(440) * 0.1
}).play;
)

// @vis drums
(
Ndef(\drums, {
    WhiteNoise.ar * 0.01
}).play;
)
SCDEOF

E2E_RESULT_FILE="$TEST_DIR/_tmp_e2e_result.txt"
rm -f "$E2E_RESULT_FILE"

# Use a different port for e2e test
E2E_PORT=$((PORT + 1))

cat > "$TEST_DIR/_tmp_e2e_test.lua" << LUAEOF
-- End-to-end integration test.
-- Loads the plugin, scans the buffer, starts OSC listener, receives UDP.

-- Add plugin to runtimepath
vim.opt.rtp:prepend("$PLUGIN_DIR")
package.path = "$PLUGIN_DIR/lua/?.lua;$PLUGIN_DIR/lua/?/init.lua;" .. package.path

local result_file = "$E2E_RESULT_FILE"
local results = {}
local function log(msg) results[#results+1] = msg end

-- Load the parser module
local ok_parser, parser = pcall(require, "sc_inline_visual.parser")
if not ok_parser then
  log("FAIL:parser_load:" .. tostring(parser))
  local f = io.open(result_file, "w"); f:write(table.concat(results, "\n")); f:close()
  vim.cmd("qa!"); return
end
log("PASS:parser_loaded")

-- Open the test file
vim.cmd("edit $TEST_DIR/_tmp_test.scd")
local bufnr = vim.api.nvim_get_current_buf()

-- CI builds the SC parser and passes its path via SC_TS_PARSER_PATH so the
-- parser tests below actually run. Locally without the env var, the test
-- relies on whatever nvim-treesitter has installed in rtp (or skips).
if vim.env.SC_TS_PARSER_PATH and vim.env.SC_TS_PARSER_PATH ~= "" then
  pcall(vim.treesitter.language.add, "supercollider",
    { path = vim.env.SC_TS_PARSER_PATH })
end

local ok_ts, ts_parser = pcall(vim.treesitter.get_parser, bufnr, "supercollider")
local has_ts = ok_ts and ts_parser ~= nil
local blocks = has_ts and parser.scan(bufnr) or {}
log("blocks_found:" .. #blocks)

if not has_ts then
  log("SKIP:parser_scan: no tree-sitter-supercollider grammar")
  log("SKIP:found_test_block: no tree-sitter-supercollider grammar")
  log("SKIP:found_drums_block: no tree-sitter-supercollider grammar")
  blocks = {
    { target = "test",  kind = "anonymous", start_line = 0, end_line = 2 },
    { target = "drums", kind = "anonymous", start_line = 4, end_line = 6 },
  }
else
  if #blocks >= 2 then
    log("PASS:parser_scan")
    for _, b in ipairs(blocks) do
      log("  block:" .. b.target .. " lines=" .. b.start_line .. "-" .. b.end_line)
    end
  else
    log("FAIL:parser_scan:found=" .. #blocks)
  end
  local found_test, found_drums = false, false
  for _, b in ipairs(blocks) do
    if b.target == "test" then found_test = true end
    if b.target == "drums" then found_drums = true end
  end
  if found_test then log("PASS:found_test_block") else log("FAIL:found_test_block") end
  if found_drums then log("PASS:found_drums_block") else log("FAIL:found_drums_block") end
end

-- Initialize state
local state = require("sc_inline_visual.state")
state.init(blocks)

-- Activate 'test' block
state.activate("test")

-- Start UDP listener on custom port
local osc_port = $E2E_PORT
local received = 0

-- Inline parser functions
local function read_osc_string(buf, pos)
  local null_pos = buf:find("\0", pos, true)
  if not null_pos then return nil, pos end
  local s = buf:sub(pos, null_pos - 1)
  local len = null_pos - pos + 1
  local padded = null_pos + 1 + (4 - (len % 4)) % 4
  return s, padded
end

local function read_float32(buf, pos)
  if pos + 3 > #buf then return 0, pos end
  local b1, b2, b3, b4 = buf:byte(pos, pos + 3)
  local sign = (b1 >= 128) and -1 or 1
  local exp = ((b1 % 128) * 2) + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 65536) + (b3 * 256) + b4
  if exp == 0 and mantissa == 0 then return 0, pos + 4 end
  if exp == 255 then return (mantissa == 0) and (sign * math.huge) or (0/0), pos + 4 end
  return sign * math.ldexp(1 + mantissa / 8388608, exp - 127), pos + 4
end

local function parse_osc(data)
  local addr, pos = read_osc_string(data, 1)
  if not addr then return nil end
  local typetag, next_pos = read_osc_string(data, pos)
  if not typetag or typetag:sub(1,1) ~= "," then return addr, {} end
  local args = {}; pos = next_pos
  for i = 2, #typetag do
    local t = typetag:sub(i,i)
    if t == "f" then
      local val; val, pos = read_float32(data, pos); args[#args+1] = val
    elseif t == "s" then
      local val; val, pos = read_osc_string(data, pos); args[#args+1] = val or ""
    else break end
  end
  return addr, args
end

local udp = vim.uv.new_udp()
local ok_bind, bind_err = udp:bind("0.0.0.0", osc_port)
if not ok_bind then
  log("FAIL:udp_bind:" .. tostring(bind_err))
  local f = io.open(result_file, "w"); f:write(table.concat(results, "\n")); f:close()
  vim.cmd("qa!"); return
end
log("PASS:udp_bind")

udp:recv_start(function(err, data, addr, flags)
  if err or not data then return end
  received = received + 1

  local osc_addr, args = parse_osc(data)
  if osc_addr == "/sc/analysis" and #args >= 3 then
    vim.schedule(function()
      state.update("analysis", args[1], args[2], args[3])
      log("osc_received:" .. osc_addr .. " target=" .. tostring(args[1]) .. " amp=" .. tostring(args[2]))
    end)
  end
end)

-- Timeout: check state and write results
local check_timer = vim.uv.new_timer()
check_timer:start(5000, 0, vim.schedule_wrap(function()
  udp:recv_stop()
  if not udp:is_closing() then udp:close() end

  log("udp_received_count:" .. received)
  if received >= 2 then
    log("PASS:udp_received")
  else
    log("FAIL:udp_received:count=" .. received)
  end

  -- Check state was updated
  local all = state.get_all()
  if all["test"] and all["test"].amp > 0 then
    log("PASS:state_updated:test.amp=" .. string.format("%.3f", all["test"].amp))
  else
    log("FAIL:state_updated:test.amp=" .. tostring(all["test"] and all["test"].amp or "nil"))
  end

  -- 'drums' should NOT be updated (it was not activated, and _master only goes to active)
  if all["drums"] and all["drums"].amp == 0 then
    log("PASS:inactive_not_updated:drums.amp=0")
  elseif all["drums"] then
    log("FAIL:inactive_not_updated:drums.amp=" .. tostring(all["drums"].amp))
  else
    log("INFO:drums_not_in_state")
  end

  -- Amp history should have entries
  if all["test"] and #all["test"].amp_history > 0 then
    log("PASS:amp_history:len=" .. #all["test"].amp_history)
  else
    log("FAIL:amp_history:empty")
  end

  local f = io.open(result_file, "w")
  f:write(table.concat(results, "\n") .. "\n")
  f:close()
  vim.cmd("qa!")
end))
LUAEOF

cat > "$TEST_DIR/_tmp_e2e_sender.py" << PYEOF
import socket, struct, time, sys

PORT = int(sys.argv[1])

def osc_string(s):
    encoded = s.encode('ascii') + b'\x00'
    padding = (4 - len(encoded) % 4) % 4
    return encoded + b'\x00' * padding

def osc_float(f):
    return struct.pack('>f', f)

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# Wait for nvim to start and bind
time.sleep(2)

# Send several analysis packets targeting _master
for i in range(5):
    amp = 0.3 + i * 0.1
    centroid = 1000.0 + i * 500.0
    msg = osc_string('/sc/analysis') + osc_string(',sff') + osc_string('_master') + osc_float(amp) + osc_float(centroid)
    sock.sendto(msg, ('127.0.0.1', PORT))
    time.sleep(0.15)

sock.close()
PYEOF

# Start nvim e2e test in background
nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_e2e_test.lua" &
E2E_PID=$!
cleanup_pids+=($E2E_PID)

# Start Python sender
python3 "$TEST_DIR/_tmp_e2e_sender.py" "$E2E_PORT" 2>&1

# Wait for nvim to finish
wait $E2E_PID 2>/dev/null || true
cleanup_pids=("${cleanup_pids[@]/$E2E_PID/}")

if [ -f "$E2E_RESULT_FILE" ]; then
  E2E_CONTENT=$(cat "$E2E_RESULT_FILE")

  # Check each expected PASS line
  check_e2e() {
    local tag="$1" desc="$2"
    if echo "$E2E_CONTENT" | grep -q "PASS:$tag"; then
      report "E2E: $desc" "PASS"
    elif echo "$E2E_CONTENT" | grep -q "SKIP:$tag"; then
      report "E2E: $desc (skipped)" "PASS"
    else
      report "E2E: $desc" "FAIL"
      echo "$E2E_CONTENT" | { grep "$tag" || true; } | head -1 | sed 's/^/  /' >&2
    fi
  }

  check_e2e "parser_loaded" "parser module loads"
  check_e2e "parser_scan" "parser finds blocks in .scd file"
  check_e2e "found_test_block" "found 'test' @vis block"
  check_e2e "found_drums_block" "found 'drums' @vis block"
  check_e2e "udp_bind" "UDP bind on port $E2E_PORT"
  check_e2e "udp_received" "UDP packets received"
  check_e2e "state_updated" "state.amp updated for active block"
  check_e2e "inactive_not_updated" "inactive block NOT updated by _master"
  check_e2e "amp_history" "amp_history populated"
else
  report "E2E: result file created" "FAIL"
  echo "  $E2E_RESULT_FILE was not created — nvim may have crashed" >&2
fi

# ─────────────────────────────────────────────────────────────
# TEST 5: _wrap_play_chain (~scvisPlayWrap) + named target state routing
# ─────────────────────────────────────────────────────────────
header "Test 5: _wrap_play_chain (~scvisPlayWrap) and named target routing"

cat > "$TEST_DIR/_tmp_wrap_test.lua" << 'LUAEOF'
-- Tests the per-block .play wrapping and routing. Wrap now emits
--   ~scvisWrap.value("<target>", <expr>).play
-- where <expr> can be a function block OR a class call (Pbind, Pdef, ...).
-- State routing keys directly off the parent target name (no aliases).

vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path

-- Stub out scnvim so require("scnvim.sclang") does not fail
package.loaded["scnvim.sclang"] = { is_running = function() return false end }
package.loaded["scnvim.editor"] = {}

local M = require("sc_inline_visual")
local state = require("sc_inline_visual.state")
local errors = {}

-- ── 5a: basic { ... }.play wrapping ──
local code_a = "{ SinOsc.ar(440) * 0.1 }.play"
local wrapped_a, did_a = M._wrap_play_chain(code_a, "block1")
if not wrapped_a:match('^~scvisWrap%.value%("block1", ') then
  errors[#errors+1] = "5a: wrapped should start with ~scvisWrap.value(\"block1\", , got: " .. wrapped_a
end
if not wrapped_a:match("%).play$") then
  errors[#errors+1] = "5a: wrapped should end with ).play, got: " .. wrapped_a
end
if did_a ~= true then
  errors[#errors+1] = "5a: did_wrap=" .. tostring(did_a) .. ", expected true"
end

-- ── 5b: .play(args) preserves arguments ──
local code_b = "{ SinOsc.ar(440) }.play(fadeTime: 2)"
local wrapped_b, did_b = M._wrap_play_chain(code_b, "block2")
if not wrapped_b:match("%).play%(fadeTime: 2%)$") then
  errors[#errors+1] = "5b: should preserve .play args, got: " .. wrapped_b
end
if did_b ~= true then
  errors[#errors+1] = "5b: did_wrap=" .. tostring(did_b) .. ", expected true"
end

-- ── 5c: nested braces ──
local code_c = "{ { SinOsc.ar(440) }.value * EnvGen.kr(Env.perc) }.play"
local wrapped_c, did_c = M._wrap_play_chain(code_c, "nested")
if not wrapped_c:match('^~scvisWrap%.value%("nested", ') then
  errors[#errors+1] = "5c: nested wrapping failed, got: " .. wrapped_c
end
if did_c ~= true then
  errors[#errors+1] = "5c: did_wrap=" .. tostring(did_c) .. ", expected true"
end
-- The inner braces should still be present
if not wrapped_c:match("{ SinOsc") then
  errors[#errors+1] = "5c: inner braces lost"
end

-- ── 5d: already Ndef — should NOT wrap ──
local code_d = 'Ndef(\\pad, { SinOsc.ar(440) }).play'
local wrapped_d, did_d = M._wrap_play_chain(code_d, "block3")
if wrapped_d ~= code_d then
  errors[#errors+1] = "5d: Ndef code should not be re-wrapped, got: " .. wrapped_d
end
if did_d ~= false then
  errors[#errors+1] = "5d: did_wrap should be false for already-Ndef code, got: " .. tostring(did_d)
end

-- ── 5e: no .play — should NOT wrap ──
local code_e = "{ SinOsc.ar(440) * 0.1 }"
local wrapped_e, did_e = M._wrap_play_chain(code_e, "block4")
if wrapped_e ~= code_e then
  errors[#errors+1] = "5e: code without .play should not be wrapped"
end
if did_e ~= false then
  errors[#errors+1] = "5e: did_wrap should be false for non-play code"
end

-- ── 5f: target embedded literally as string arg ──
local wrapped_f, did_f = M._wrap_play_chain("{ DC.ar(0) }.play", "myTarget")
if not wrapped_f:match('~scvisWrap%.value%("myTarget", ') then
  errors[#errors+1] = "5f: target arg wrong, got: " .. wrapped_f
end
if did_f ~= true then
  errors[#errors+1] = "5f: did_wrap=" .. tostring(did_f) .. ", expected true"
end

-- ── 5h: Pbind(...).play wraps via ).play branch ──
local code_h = 'Pbind(\\freq, 440, \\dur, 0.2).play'
local wrapped_h, did_h = M._wrap_play_chain(code_h, "pat1")
if not wrapped_h:match('^~scvisWrap%.value%("pat1", Pbind%(') then
  errors[#errors+1] = "5h: Pbind wrap failed, got: " .. wrapped_h
end
if not wrapped_h:match('%)%.play$') then
  errors[#errors+1] = "5h: wrapped should end with ).play, got: " .. wrapped_h
end
if did_h ~= true then
  errors[#errors+1] = "5h: did_wrap=" .. tostring(did_h) .. ", expected true"
end

-- ── 5i: Pdef(\name, Pbind(...)).play wraps the outer Pdef ──
local code_i = 'Pdef(\\foo, Pbind(\\freq, 440)).play'
local wrapped_i, did_i = M._wrap_play_chain(code_i, "pat2")
if not wrapped_i:match('^~scvisWrap%.value%("pat2", Pdef%(') then
  errors[#errors+1] = "5i: Pdef wrap failed, got: " .. wrapped_i
end
-- The full Pdef expression (incl. nested Pbind) must be inside the wrap arg.
if not wrapped_i:match('Pbind%(\\\\?freq, 440%)%)%)%.play$') then
  errors[#errors+1] = "5i: inner Pbind lost or wrap closed early, got: " .. wrapped_i
end
if did_i ~= true then
  errors[#errors+1] = "5i: did_wrap=" .. tostring(did_i) .. ", expected true"
end

-- ── 5j: Ndef in the code still bypasses wrap (uses ~scvisTrackNdef path) ──
local code_j = 'Ndef(\\bass, { SinOsc.ar(110) * 0.1 }).play'
local wrapped_j, did_j = M._wrap_play_chain(code_j, "block5")
if wrapped_j ~= code_j or did_j ~= false then
  errors[#errors+1] = "5j: Ndef should not be wrapped, got: " .. wrapped_j
end

-- ── 5k: Event literal (instrument: ...).play wraps with no class prefix ──
-- The receiver is the entire `(...)` Event literal — no class identifier
-- precedes the open paren, so the backward walk must stop at the `(`.
local code_k = '(instrument: \\bpf_brown, freq: 500, atk: 2, rel: 4, amp: 0.6).play'
local wrapped_k, did_k = M._wrap_play_chain(code_k, "ev1")
if not wrapped_k:match('^~scvisWrap%.value%("ev1", %(instrument:') then
  errors[#errors+1] = "5k: Event wrap failed, got: " .. wrapped_k
end
if not wrapped_k:match('%)%.play$') then
  errors[#errors+1] = "5k: wrapped should end with ).play, got: " .. wrapped_k
end
if did_k ~= true then
  errors[#errors+1] = "5k: did_wrap=" .. tostring(did_k) .. ", expected true"
end

-- ── 5g: wrapped blocks get per-block data, non-wrapped get _master ──
-- Simulate: parser found block1, block2, block3 as anonymous blocks.
-- Plugin wrapped block1 and block2 (calls state.mark_wrapped for each).
-- block3 was not wrapped (e.g. no `{ ... }.play` in its body).
local blocks = {
  { target = "block1", kind = "anonymous", start_line = 0, end_line = 5 },
  { target = "block2", kind = "anonymous", start_line = 7, end_line = 12 },
  { target = "block3", kind = "anonymous", start_line = 14, end_line = 20 },
}
state.init(blocks)

state.mark_wrapped("block1")
state.mark_wrapped("block2")
-- block3 is NOT wrapped

state.activate("block1")
state.activate("block2")
state.activate("block3")

-- SC now tags per-block messages with the parent name directly.
state.update("analysis", "block1", 0.8, 3000.0)
state.update("analysis", "block2", 0.3, 1000.0)
state.update("analysis", "_master", 0.5, 2000.0)

local all = state.get_all()

if math.abs(all["block1"].amp - 0.8) > 0.001 then
  errors[#errors+1] = "5g: block1.amp=" .. all["block1"].amp .. ", expected 0.8 (per-block, not _master)"
end
if math.abs(all["block2"].amp - 0.3) > 0.001 then
  errors[#errors+1] = "5g: block2.amp=" .. all["block2"].amp .. ", expected 0.3 (per-block, not _master)"
end
if math.abs(all["block3"].amp - 0.5) > 0.001 then
  errors[#errors+1] = "5g: block3.amp=" .. all["block3"].amp .. ", expected 0.5 (from _master)"
end

state.reset()

if #errors == 0 then
  print("WRAP_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  wrap error: " .. e .. "\n") end
  print("WRAP_RESULT:FAIL")
end
LUAEOF

WRAP_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_wrap_test.lua" \
  -c "qa!" 2>&1 | grep "WRAP_RESULT:" | head -1 || true)

if [[ "$WRAP_RESULT" == *":PASS"* ]]; then
  report "wrap: basic {}.play wrapped to ~scvisWrap" "PASS"
  report "wrap: preserves .play(args)" "PASS"
  report "wrap: handles nested braces" "PASS"
  report "wrap: skips already-Ndef code" "PASS"
  report "wrap: skips code without .play" "PASS"
  report "wrap: target string embedded correctly" "PASS"
  report "wrap: Pbind(...).play wraps via ).play branch" "PASS"
  report "wrap: Pdef(\\name, Pbind()).play wraps the outer Pdef" "PASS"
  report "wrap: Ndef code still bypasses wrap" "PASS"
  report "wrap: (instrument: \\name, ...).play (Event literal) wraps" "PASS"
  report "State: wrapped blocks get per-block data, non-wrapped get _master" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_wrap_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 5: wrap / named target routing" "FAIL"
fi

# ─────────────────────────────────────────────────────────────
# TEST 6: pattern widget beat grid
# ─────────────────────────────────────────────────────────────
header "Test 6: pattern widget beat grid + playhead"

cat > "$TEST_DIR/_tmp_grid_test.lua" << 'LUAEOF'
-- Verify that the snap-only beat grid row renders with `│··` cells and that
-- the playhead (▲) lands on the column matching `current_step % n_cells`.
vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path
package.loaded["scnvim.sclang"] = { is_running = function() return false end }
package.loaded["scnvim.editor"] = {}

local widgets_pat = require("sc_inline_visual.widgets.pattern")
local errors = {}

-- Concatenate the text content of a segment list into a flat string.
local function flatten(segs)
  local parts = {}
  for _, seg in ipairs(segs) do
    parts[#parts + 1] = seg[1]
  end
  return table.concat(parts)
end

-- ── 6a: grid with no playhead (current_step nil) is all │ ──
local segs_a = widgets_pat._beat_grid(nil, 4, 3)
local text_a = flatten(segs_a)
if text_a ~= "  beat │··│··│··│··" then
  errors[#errors+1] = "6a: idle grid mismatch, got: '" .. text_a .. "'"
end

-- ── 6b: playhead at step 0 -> first `│` becomes `▲` ──
local segs_b = widgets_pat._beat_grid(0, 4, 3)
local text_b = flatten(segs_b)
if text_b ~= "  beat ▲··│··│··│··" then
  errors[#errors+1] = "6b: step 0 grid mismatch, got: '" .. text_b .. "'"
end

-- ── 6c: playhead at step 2 -> third `│` becomes `▲` ──
local segs_c = widgets_pat._beat_grid(2, 4, 3)
local text_c = flatten(segs_c)
if text_c ~= "  beat │··│··▲··│··" then
  errors[#errors+1] = "6c: step 2 grid mismatch, got: '" .. text_c .. "'"
end

-- ── 6d: playhead modulos around n_cells (step 6 of 4-cell grid) ──
local segs_d = widgets_pat._beat_grid(6, 4, 3)
local text_d = flatten(segs_d)
if text_d ~= "  beat │··│··▲··│··" then
  errors[#errors+1] = "6d: step 6 (=2 mod 4) mismatch, got: '" .. text_d .. "'"
end

-- ── 6e: pattern_preview appends a grid row after the value rows ──
local params = {
  { key = "midinote", values = { 60, 62, 67 } },
}
local rows = widgets_pat.pattern_preview(params, 1)
-- Expect: separator row, midinote row, grid row = 3 rows
if #rows ~= 3 then
  errors[#errors+1] = "6e: expected 3 rows (sep+midi+grid), got: " .. #rows
end
local grid_text = flatten(rows[#rows])
if not grid_text:match("^  beat ") then
  errors[#errors+1] = "6e: last row should be the beat grid, got: '" .. grid_text .. "'"
end
if not grid_text:match("▲") then
  errors[#errors+1] = "6e: grid should contain a ▲ playhead, got: '" .. grid_text .. "'"
end

-- ── 6f: pattern_preview without current_step renders grid with no ▲ ──
local rows_f = widgets_pat.pattern_preview(params, nil)
local grid_f = flatten(rows_f[#rows_f])
if grid_f:match("▲") then
  errors[#errors+1] = "6f: idle pattern should not have a playhead, got: '" .. grid_f .. "'"
end

if #errors == 0 then
  print("GRID_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  grid error: " .. e .. "\n") end
  print("GRID_RESULT:FAIL")
end
LUAEOF

GRID_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_grid_test.lua" \
  -c "qa!" 2>&1 | grep "GRID_RESULT:" | head -1 || true)

if [[ "$GRID_RESULT" == *":PASS"* ]]; then
  report "grid: idle row is all │" "PASS"
  report "grid: ▲ at step 0 column" "PASS"
  report "grid: ▲ at step 2 column" "PASS"
  report "grid: ▲ wraps modulo n_cells" "PASS"
  report "grid: pattern_preview appends grid row" "PASS"
  report "grid: idle pattern has no ▲" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_grid_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 6: pattern widget beat grid" "FAIL"
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
printf "\n\033[1m=== Summary ===\033[0m\n"
printf "  Total: %d   \033[32mPassed: %d\033[0m   \033[31mFailed: %d\033[0m\n\n" "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  exit 0
fi
