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

-- 3k: record_event pushes onto pat_history and activates the block
state.init(blocks)
if #all["synth1"].pat_history ~= 0 then
  errors[#errors+1] = "3k: initial pat_history len=" .. #all["synth1"].pat_history .. ", expected 0"
end
state.record_event("synth1", 60, -999, -1, 0.2, 0.5)
state.record_event("synth1", 62, -999, -1, 0.2, 0.5)
state.record_event("synth1", 67, -999, -1, 0.3, 0.6)
all = state.get_all()
if #all["synth1"].pat_history ~= 3 then
  errors[#errors+1] = "3k: after 3 records pat_history len=" .. #all["synth1"].pat_history .. ", expected 3"
end
if all["synth1"].pat_history[3].midinote ~= 67 then
  errors[#errors+1] = "3k: last event midinote=" .. tostring(all["synth1"].pat_history[3].midinote) .. ", expected 67"
end
if not all["synth1"].active then
  errors[#errors+1] = "3k: record_event should activate the block"
end

-- 3l: pat_history caps at PAT_HISTORY_LEN (=8); older entries fall off the left
for i = 1, 10 do state.record_event("synth1", 60 + i, -999, -1, 0.1, 0.5) end
all = state.get_all()
if #all["synth1"].pat_history ~= 8 then
  errors[#errors+1] = "3l: pat_history should cap at 8, got " .. #all["synth1"].pat_history
end
-- Earliest surviving event should be the one with midinote 63 (3 + 10 records - 8 kept = entry 6 of 13)
if all["synth1"].pat_history[1].midinote ~= 63 then
  errors[#errors+1] = "3l: oldest surviving event midinote=" .. tostring(all["synth1"].pat_history[1].midinote) .. ", expected 63"
end

-- 3m: record_event on unknown target is a no-op
state.record_event("nonexistent", 60, -999, -1, 0.2, 0.5)  -- should not error

-- 3n: reset clears everything
state.reset()
all = state.get_all()
local count = 0
for _ in pairs(all) do count = count + 1 end
if count ~= 0 then
  errors[#errors+1] = "3n: after reset, state count=" .. count .. ", expected 0"
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
  report "State: record_event pushes onto pat_history + activates" "PASS"
  report "State: pat_history caps at PAT_HISTORY_LEN" "PASS"
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

-- _wrap_play_chain uses tree-sitter on the code string. Register the SC
-- grammar from SC_TS_PARSER_PATH (the same env var the e2e test uses); when
-- it isn't available, every wrap assertion below is reported as SKIP.
if vim.env.SC_TS_PARSER_PATH and vim.env.SC_TS_PARSER_PATH ~= "" then
  pcall(vim.treesitter.language.add, "supercollider",
    { path = vim.env.SC_TS_PARSER_PATH })
end
local has_ts = pcall(vim.treesitter.get_string_parser, "(\n).play", "supercollider")

local M = require("sc_inline_visual")
local state = require("sc_inline_visual.state")
local errors = {}

if not has_ts then
  print("WRAP_RESULT:SKIP")
  os.exit(0)
end

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

-- ── 5l: method-chain receiver (~seq.next(()).play) is captured whole ──
-- The walk-back must skip past the `.next(())` segment to grab `~seq` too,
-- otherwise the wrap inserts `~scvisWrap.value(...)` between `~seq.` and
-- `next(())`, producing a syntax error in sclang.
local code_l = '~seq.next(()).play'
local wrapped_l, did_l = M._wrap_play_chain(code_l, "chain1")
if not wrapped_l:match('^~scvisWrap%.value%("chain1", ~seq%.next%(%(%)%)%)%.play$') then
  errors[#errors+1] = "5l: method chain wrap mangled, got: " .. wrapped_l
end
if did_l ~= true then
  errors[#errors+1] = "5l: did_wrap=" .. tostring(did_l) .. ", expected true"
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

WRAP_LABELS=(
  "wrap: basic {}.play wrapped to ~scvisWrap"
  "wrap: preserves .play(args)"
  "wrap: handles nested braces"
  "wrap: skips already-Ndef code"
  "wrap: skips code without .play"
  "wrap: target string embedded correctly"
  "wrap: Pbind(...).play wraps via ).play branch"
  "wrap: Pdef(\\name, Pbind()).play wraps the outer Pdef"
  "wrap: Ndef code still bypasses wrap"
  "wrap: (instrument: \\name, ...).play (Event literal) wraps"
  "wrap: method-chain receiver (~seq.next(()).play) captured whole"
  "State: wrapped blocks get per-block data, non-wrapped get _master"
)

if [[ "$WRAP_RESULT" == *":PASS"* ]]; then
  for label in "${WRAP_LABELS[@]}"; do report "$label" "PASS"; done
elif [[ "$WRAP_RESULT" == *":SKIP"* ]]; then
  # _wrap_play_chain now uses tree-sitter, which needs the SC grammar
  # registered via SC_TS_PARSER_PATH. Without it we report skips so the
  # rest of the suite still runs cleanly.
  for label in "${WRAP_LABELS[@]}"; do report "$label (skipped)" "PASS"; done
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_wrap_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 5: wrap / named target routing" "FAIL"
fi

# ─────────────────────────────────────────────────────────────
# TEST 6: pattern widget — live history rendering
# ─────────────────────────────────────────────────────────────
header "Test 6: pattern widget — live event history rendering"

cat > "$TEST_DIR/_tmp_grid_test.lua" << 'LUAEOF'
-- Verify that pattern_preview renders one row per user key, pulling cells
-- from the live pat_history (most recent in the rightmost slot), with dim
-- placeholders padding the left when fewer than WINDOW events have arrived.
vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path
package.loaded["scnvim.sclang"] = { is_running = function() return false end }
package.loaded["scnvim.editor"] = {}

local widgets_pat = require("sc_inline_visual.widgets.pattern")
local errors = {}

local function flatten(segs)
  local parts = {}
  for _, seg in ipairs(segs) do
    parts[#parts + 1] = seg[1]
  end
  return table.concat(parts)
end

-- ── 6a: empty history -> all-placeholder row, no real notes ──
local params = { { key = "midinote" } }
local rows_a = widgets_pat.pattern_preview(params, {})
-- Expect: separator + midi row = 2 rows
if #rows_a ~= 2 then
  errors[#errors+1] = "6a: expected 2 rows (sep + midi), got: " .. #rows_a
end
local text_a = flatten(rows_a[2])
if text_a:match("C") or text_a:match("D") or text_a:match("E") then
  errors[#errors+1] = "6a: empty history row should not contain note names, got: '" .. text_a .. "'"
end
local dot_count = 0
for _ in text_a:gmatch("·") do
  dot_count = dot_count + 1
end
if dot_count < 8 then
  errors[#errors+1] = "6a: expected at least 8 placeholder dots, got " .. dot_count
end

-- ── 6b: history with 3 events -> note names in rightmost 3 slots ──
local hist_b = {
  { midinote = 60 }, -- C4
  { midinote = 62 }, -- D4
  { midinote = 67 }, -- G4
}
local rows_b = widgets_pat.pattern_preview(params, hist_b)
local text_b = flatten(rows_b[2])
if not (text_b:match("C4") and text_b:match("D4") and text_b:match("G4")) then
  errors[#errors+1] = "6b: history events not rendered as notes, got: '" .. text_b .. "'"
end
-- Last event (G4) should land after C4 and D4 (rightmost == most recent).
local pos_c, pos_d, pos_g = text_b:find("C4"), text_b:find("D4"), text_b:find("G4")
if not (pos_c and pos_d and pos_g and pos_c < pos_d and pos_d < pos_g) then
  errors[#errors+1] = "6b: events should appear in time order, got positions C4="
    .. tostring(pos_c) .. " D4=" .. tostring(pos_d) .. " G4=" .. tostring(pos_g)
end

-- ── 6c: SC sentinel values fall back to placeholder, not garbage ──
-- midinote = -1 means SC's Pbind didn't resolve a \midinote for this event.
local hist_c = {
  { midinote = -1 },
  { midinote = 60 },
}
local rows_c = widgets_pat.pattern_preview(params, hist_c)
local text_c = flatten(rows_c[2])
-- The -1 should not render as a note (e.g. as "C-2" or similar negative MIDI).
if text_c:match("C%-") or text_c:match("%-1") or text_c:match("%-2") then
  errors[#errors+1] = "6c: sentinel -1 leaked into render: '" .. text_c .. "'"
end

-- ── 6d: multiple keys -> one row per key plus the separator ──
local params_d = {
  { key = "midinote" },
  { key = "amp" },
  { key = "dur" },
}
local rows_d = widgets_pat.pattern_preview(params_d, hist_b)
if #rows_d ~= 4 then
  errors[#errors+1] = "6d: expected 4 rows (sep + 3 keys), got: " .. #rows_d
end

-- ── 6e: no params -> empty list (no separator, no rows) ──
local rows_e = widgets_pat.pattern_preview({}, hist_b)
if #rows_e ~= 0 then
  errors[#errors+1] = "6e: empty params should return no rows, got: " .. #rows_e
end

if #errors == 0 then
  print("GRID_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  pat error: " .. e .. "\n") end
  print("GRID_RESULT:FAIL")
end
LUAEOF

GRID_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_grid_test.lua" \
  -c "qa!" 2>&1 | grep "GRID_RESULT:" | head -1 || true)

if [[ "$GRID_RESULT" == *":PASS"* ]]; then
  report "pat: idle history renders placeholder dots" "PASS"
  report "pat: history events render in time order (newest at right)" "PASS"
  report "pat: SC sentinel value falls back to placeholder" "PASS"
  report "pat: one row per key + separator" "PASS"
  report "pat: empty params returns no rows" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_grid_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 6: pattern widget live history" "FAIL"
fi

header "Test 7: LFO/Noise inline sparkline (static simulation)"

cat > "$TEST_DIR/_tmp_lfo_test.lua" << 'LUAEOF'
-- Verify the static LFO sparkline analyzer: detects control-rate UGens,
-- simulates a representative trace, ignores comments and audio-rate carriers,
-- and reflects the range mapping in the label.
vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path

local lfo = require("sc_inline_visual.lfo")
local errors = {}

-- 7a: a control-rate noise UGen with exprange is detected, with full label.
local r = lfo.analyze_line("var cutoff = LFNoise1.kr(0.3).exprange(300, 3000);")
if not r then
  errors[#errors+1] = "7a: LFNoise1.kr not detected"
else
  if r.name ~= "LFNoise1" then errors[#errors+1] = "7a: wrong name " .. tostring(r.name) end
  if #r.values ~= lfo.N then errors[#errors+1] = "7a: expected " .. lfo.N .. " samples, got " .. #r.values end
  if not (r.label:match("0.3Hz") and r.label:match("300") and r.label:match("3k")) then
    errors[#errors+1] = "7a: label missing freq/range: '" .. r.label .. "'"
  end
  for _, v in ipairs(r.values) do
    if v < 0 or v > 1 then errors[#errors+1] = "7a: value out of [0,1]: " .. v break end
  end
end

-- 7b: a comment containing a UGen must NOT be detected.
if lfo.analyze_line("// SinOsc.kr(2).range(1, 2) is just a note") ~= nil then
  errors[#errors+1] = "7b: UGen inside a comment was matched"
end

-- 7c: audio-rate carriers (.ar) are intentionally ignored.
if lfo.analyze_line("Out.ar(0, SinOsc.ar(440) * 0.1);") ~= nil then
  errors[#errors+1] = "7c: audio-rate .ar oscillator should be ignored"
end

-- 7d: a plain expression with no UGen returns nil.
if lfo.analyze_line("var x = a + b * 2;") ~= nil then
  errors[#errors+1] = "7d: non-UGen line matched"
end

-- 7e: deterministic — same source yields the same trace (no flicker).
local a1 = lfo.analyze_line("z = LFNoise0.kr(8).range(0,1);")
local a2 = lfo.analyze_line("z = LFNoise0.kr(8).range(0,1);")
for i = 1, #a1.values do
  if a1.values[i] ~= a2.values[i] then errors[#errors+1] = "7e: trace not deterministic" break end
end

-- 7f: a deterministic periodic shape actually varies (not a flat line).
local sine = lfo.analyze_line("o = SinOsc.kr(2).range(0,1);")
local lo, hi = 1, 0
for _, v in ipairs(sine.values) do lo = math.min(lo, v); hi = math.max(hi, v) end
if (hi - lo) < 0.5 then errors[#errors+1] = "7f: SinOsc trace too flat (" .. lo .. ".." .. hi .. ")" end

-- 7g: Line/XLine one-shot ramps — direction-aware, spec-free, no false collision.
local up = lfo.analyze_line("e = Line.kr(200, 2000, 1);")
if not up or up.name ~= "Line" then errors[#errors+1] = "7g: Line not detected" end
if up and not (up.values[1] < 0.1 and up.values[#up.values] > 0.9) then errors[#errors+1] = "7g: Line should ramp up" end
if up and not up.label:find("↗") then errors[#errors+1] = "7g: Line label missing ↗ (" .. (up.label or "") .. ")" end
local down = lfo.analyze_line("f = XLine.kr(2000, 200, 1);")
if not down or down.name ~= "XLine" then errors[#errors+1] = "7g: XLine not detected" end
if down and not (down.values[1] > 0.9 and down.values[#down.values] < 0.1) then errors[#errors+1] = "7g: XLine should ramp down" end
-- XLine is exponential: descending from a high start dwells low quickly (mid sample well under 0.5).
if down and not (down.values[8] < 0.4) then errors[#errors+1] = "7g: XLine not exp-curved (mid=" .. tostring(down.values[8]) .. ")" end
-- `Line` must NOT match inside `XLine`, and `.ar` ramps are ignored like other carriers.
if lfo.analyze_line("Line.ar(0, 1, 1);") ~= nil then errors[#errors+1] = "7g: Line.ar should be ignored" end

if #errors == 0 then
  print("LFO_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  lfo error: " .. e .. "\n") end
  print("LFO_RESULT:FAIL")
end
LUAEOF

LFO_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_lfo_test.lua" \
  -c "qa!" 2>&1 | grep "LFO_RESULT:" | head -1 || true)

if [[ "$LFO_RESULT" == *":PASS"* ]]; then
  report "lfo: control-rate UGen detected with freq/range label" "PASS"
  report "lfo: UGen inside a comment is ignored" "PASS"
  report "lfo: audio-rate (.ar) carrier is ignored" "PASS"
  report "lfo: non-UGen line returns nil" "PASS"
  report "lfo: same source yields a deterministic trace" "PASS"
  report "lfo: periodic shape varies across the window" "PASS"
  report "lfo: Line/XLine ramps render direction + exp curve" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_lfo_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 7: LFO sparkline" "FAIL"
fi

header "Test 8: cursor-on-key row highlight"

cat > "$TEST_DIR/_tmp_cursor_test.lua" << 'LUAEOF'
-- Verify key_at_cursor maps a cursor position to the Pbind key whose value
-- expression it sits in, and that the widget brightens exactly that row.
vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path

local pattern = require("sc_inline_visual.pattern")
local widgets = require("sc_inline_visual.widgets")
local errors = {}

local lines = {
  "Pbind(",
  "  \\degree, Pseq([0,1,2], inf),",
  "  \\dur, Pseq([0.25, 0.5], inf),",
  "  \\amp, Pwhite(0.1, 0.3),",
  "  \\scale, \\minor",
  ").play;",
}
local start = 5
local params = pattern.parse_pbind(table.concat(lines, "\n"))

local function probe(line, col) return pattern.key_at_cursor(lines, start, params, line, col) end

-- 8a: cursor inside each key's value expr resolves to that key.
if probe(6, 20) ~= "degree" then errors[#errors+1] = "8a: degree value -> " .. tostring(probe(6,20)) end
if probe(7, 10) ~= "dur" then errors[#errors+1] = "8a: dur value -> " .. tostring(probe(7,10)) end
if probe(8, 10) ~= "amp" then errors[#errors+1] = "8a: amp value -> " .. tostring(probe(8,10)) end

-- 8b: on the \degree token itself still highlights degree.
if probe(6, 2) ~= "degree" then errors[#errors+1] = "8b: on token -> " .. tostring(probe(6,2)) end

-- 8c: before any key (on "Pbind(") highlights nothing.
if probe(5, 3) ~= nil then errors[#errors+1] = "8c: pre-key should be nil, got " .. tostring(probe(5,3)) end

-- 8d: a non-rendered key region (\scale, \minor) highlights nothing, not the
-- previous rendered key.
if probe(9, 10) ~= nil then errors[#errors+1] = "8d: non-rendered key should be nil, got " .. tostring(probe(9,10)) end

-- 8e: the widget brightens exactly the active row's label.
local function label_hl(rows, key)
  for _, row in ipairs(rows) do
    local txt = row[1][1]
    if txt:match(key:sub(1,4)) then return row[1][2] end
  end
end
local fut = { { degree = 0, dur = 0.25, amp = 0.2 } }
local rows = widgets.pattern_future(params, fut, "dur")
if label_hl(rows, "dur") ~= "SCInlineVisualActive" then
  errors[#errors+1] = "8e: active row not highlighted, got " .. tostring(label_hl(rows, "dur"))
end
if label_hl(rows, "degr") == "SCInlineVisualActive" then
  errors[#errors+1] = "8e: inactive row should not be highlighted"
end
-- nil active key -> no row highlighted.
local rows_none = widgets.pattern_future(params, fut, nil)
for _, row in ipairs(rows_none) do
  if row[1][2] == "SCInlineVisualActive" then errors[#errors+1] = "8e: nil active highlighted a row" break end
end

if #errors == 0 then
  print("CURSOR_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  cursor error: " .. e .. "\n") end
  print("CURSOR_RESULT:FAIL")
end
LUAEOF

CURSOR_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_cursor_test.lua" \
  -c "qa!" 2>&1 | grep "CURSOR_RESULT:" | head -1 || true)

if [[ "$CURSOR_RESULT" == *":PASS"* ]]; then
  report "cursor: value-expr resolves to its key" "PASS"
  report "cursor: on the key token highlights the key" "PASS"
  report "cursor: before any key highlights nothing" "PASS"
  report "cursor: non-rendered key region highlights nothing" "PASS"
  report "cursor: widget brightens exactly the active row" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_cursor_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 8: cursor row highlight" "FAIL"
fi

header "Test 9: keyboard scrub (number detection, stepping, live-set mapping)"

cat > "$TEST_DIR/_tmp_scrub_test.lua" << 'LUAEOF'
-- Verify the scrub core: locate the literal under the cursor, step it at its
-- own precision, and resolve only Ndef/Pbindef controls to a live .set command.
vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path

local scrub = require("sc_inline_visual.scrub")
local errors = {}
local function colof(line, needle) return (line:find(needle, 1, true)) - 1 end

-- 9a: number detection + precision.
local function tok(line, needle) return scrub.find_number(line, colof(line, needle)) end
local t = tok("  \\dur, 0.25,", "0.25")
if not (t and t.value == 0.25 and t.decimals == 2) then errors[#errors+1] = "9a: 0.25 decimals" end
if tok("LFNoise0.kr(0.3)", "0.3").value ~= 0.3 then errors[#errors+1] = "9a: LFNoise0 digit confused detection" end
if scrub.find_number("5.rand", 0) ~= nil then errors[#errors+1] = "9a: method receiver 5.rand scrubbed" end
if scrub.find_number("Out.ar(bus)", 3) ~= nil then errors[#errors+1] = "9a: matched a non-number" end

-- 9b: stepping preserves precision and handles big step / sign.
local function step(line, needle, n) return scrub.step_value(tok(line, needle), n) end
if step("\\freq.kr(440)", "440", 1) ~= "441" then errors[#errors+1] = "9b: 440+1" end
if step("\\dur, 0.25", "0.25", 1) ~= "0.26" then errors[#errors+1] = "9b: 0.25+1 precision" end
if step("\\dur, 0.25", "0.25", -30) ~= "-0.05" then errors[#errors+1] = "9b: 0.25-30 -> " .. step("\\dur, 0.25", "0.25", -30) end
-- ControlSpec range clamps the stepped value; unknown names have no spec.
if scrub.spec_bounds("dur") ~= nil then errors[#errors+1] = "9b: dur should have no spec" end
if scrub.step_value(tok("\\freq.kr(440)", "440"), -1000, scrub.spec_bounds("freq")) ~= "20" then errors[#errors+1] = "9b: freq clamps to 20" end
if scrub.step_value(tok("\\amp.kr(0.5)", "0.5"), 100, scrub.spec_bounds("amp")) ~= "1.0" then errors[#errors+1] = "9b: amp clamps to 1.0" end

-- 9c: detect + command map only Ndef NamedControl + Pbindef key.
local function cmd(line, needle, src, target, v)
  local k = tok(line, needle)
  local d = scrub.detect(line, k.s, k.e) -- mirror init.M.scrub: detect, then build off the block
  if not d then return nil end
  return scrub.command(d, target, src, v)
end
local ndef = "Ndef(\\lead, { SinOsc.ar(\\freq.kr(440)) })"
if cmd(ndef, "440", ndef, "lead", "441") ~= "Ndef(\\lead).set(\\freq, 441)" then errors[#errors+1] = "9c: Ndef set" end
local pb = "Pbindef(\\bd, \\dur, 0.25)"
if cmd(pb, "0.25", pb, "bd", "0.26") ~= "Pbindef(\\bd, \\dur, 0.26)" then errors[#errors+1] = "9c: Pbindef set" end
-- not live-settable: number inside a Pseq array, anon synth, plain Pdef.
if cmd("  \\dur, Pseq([0.25, 0.5], inf)", "0.25", "Pbindef(\\x, ...", "x", "0.26") ~= nil then errors[#errors+1] = "9c: Pseq element should be nil" end
local anon = "{ SinOsc.ar(\\freq.kr(440)) }.play"
if cmd(anon, "440", anon, "block1", "441") ~= nil then errors[#errors+1] = "9c: anon synth should be nil" end
local pdef = "Pdef(\\x, Pbind(\\dur, 0.25))"
if cmd(pdef, "0.25", pdef, "x", "0.26") ~= nil then errors[#errors+1] = "9c: plain Pdef should be nil" end

-- 9d: a synth-function arg default bound to a var resolves to `<var>.set`.
local pipe = "x = { |freq = 220| SinOsc.ar(freq, 0, 0.1) }.play;"
if cmd(pipe, "220", pipe, "block1", "230") ~= "x.set(\\freq, 230)" then errors[#errors+1] = "9d: pipe arg -> x.set" end
local argkw = "~lead = { arg cutoff = 800; LPF.ar(in, cutoff) }.play;"
if cmd(argkw, "800", argkw, "block2", "810") ~= "~lead.set(\\cutoff, 810)" then errors[#errors+1] = "9d: arg keyword -> ~lead.set" end
local multi = "y = { |freq = 220, amp = 0.1| (SinOsc.ar(freq) * amp) }.play;"
if cmd(multi, "0.1", multi, "block3", "0.2") ~= "y.set(\\amp, 0.2)" then errors[#errors+1] = "9d: 2nd arg -> y.set(amp)" end
-- a bare `{ ... }.play` has no handle to .set, so no live command.
local bare = "{ |freq = 220| SinOsc.ar(freq) }.play"
if cmd(bare, "220", bare, "block4", "230") ~= nil then errors[#errors+1] = "9d: handle-less synth should be nil" end

-- 9e: source-value sliders — scan_controls extracts spec-backed controls (in
-- first-seen order, deduped, non-spec names dropped) and unmap honors warp.
local specs = require("sc_inline_visual.specs")
local function L(s) local t = {} for ln in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = ln end return t end
local sc1 = scrub.scan_controls(L("Ndef(\\lead, { VarSaw.ar(\\freq.kr(440), 0, 0.4) * \\amp.kr(0.1) })"))
if not (#sc1 == 2 and sc1[1].name == "freq" and sc1[1].value == 440 and sc1[2].name == "amp") then
  errors[#errors+1] = "9e: Ndef control scan (got " .. #sc1 .. ")"
end
-- \dur has no spec → dropped; only \freq/\amp become sliders.
local sc2 = scrub.scan_controls(L("Pbindef(\\bd, \\dur, 0.25, \\freq, 220, \\amp, 0.2)"))
if not (#sc2 == 2 and sc2[1].name == "freq" and sc2[2].name == "amp") then errors[#errors+1] = "9e: non-spec \\dur should drop" end
-- negative default keeps its sign via find_number's unary-minus fold.
local sc3 = scrub.scan_controls(L("{ Pan2.ar(sig, \\pan.kr(-0.5)) }"))
if not (#sc3 == 1 and sc3[1].name == "pan" and sc3[1].value == -0.5) then errors[#errors+1] = "9e: negative default" end
-- unmap: linear midpoint, exp-warped freq midpoint, out-of-range clamps.
if math.abs(specs.unmap(specs.get("amp"), 0.5) - 0.5) > 1e-9 then errors[#errors+1] = "9e: amp lin mid" end
if math.abs(specs.unmap(specs.get("freq"), 632.4555) - 0.5) > 1e-3 then errors[#errors+1] = "9e: freq exp mid" end
if specs.unmap(specs.get("amp"), 9) ~= 1 then errors[#errors+1] = "9e: clamp over max" end

if #errors == 0 then
  print("SCRUB_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  scrub error: " .. e .. "\n") end
  print("SCRUB_RESULT:FAIL")
end
LUAEOF

SCRUB_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_scrub_test.lua" \
  -c "qa!" 2>&1 | grep "SCRUB_RESULT:" | head -1 || true)

if [[ "$SCRUB_RESULT" == *":PASS"* ]]; then
  report "scrub: number detection skips identifiers/method receivers" "PASS"
  report "scrub: stepping preserves the literal's precision" "PASS"
  report "scrub: ControlSpec range clamps the stepped value" "PASS"
  report "scrub: Ndef NamedControl resolves to a live .set" "PASS"
  report "scrub: Pbindef key resolves to a live update" "PASS"
  report "scrub: synth-function arg bound to a var resolves to <var>.set" "PASS"
  report "scrub: non-settable numbers map to no command" "PASS"
  report "scrub: scan_controls extracts spec-backed sliders (warp-aware)" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_scrub_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 9: keyboard scrub" "FAIL"
fi

header "Test 10: envelope curve parsing + curved interpolation"

cat > "$TEST_DIR/_tmp_env_test.lua" << 'LUAEOF'
-- Verify Env curves: parse attaches the right curve per segment (default,
-- numeric, named symbol, Env.new per-segment array) and the widget actually
-- bends the plot (a curved decay differs from a linear one and dwells lower).
vim.opt.rtp:prepend(vim.env.PLUGIN_DIR)
package.path = vim.env.PLUGIN_DIR .. "/lua/?.lua;" .. vim.env.PLUGIN_DIR .. "/lua/?/init.lua;" .. package.path

local env = require("sc_inline_visual.env")
local w = require("sc_inline_visual.widgets.env")
local errors = {}

-- 10a: curve attaches to breakpoints with SC defaults / explicit values.
local function curve_of(src, idx) local e = env.parse(src); return e and e.points[idx] and e.points[idx].c end
if curve_of("Env.perc(0.01, 1.0)", 3) ~= -4 then errors[#errors+1] = "10a: perc default curve -4" end
if curve_of("Env.adsr(0.01, 0.2, 0.5, 1)", 2) ~= -4 then errors[#errors+1] = "10a: adsr default -4" end
if curve_of("Env.perc(0.01, 1, 1, \\sin)", 3) ~= "sin" then errors[#errors+1] = "10a: perc \\sin symbol" end
if curve_of("Env.perc(0.01, 1, 1, -8)", 3) ~= -8 then errors[#errors+1] = "10a: perc numeric -8" end
if curve_of("Env([0,1,0], [1,1])", 2) ~= "lin" then errors[#errors+1] = "10a: Env.new default lin" end

-- 10b: Env.new per-segment curve array (wraps if short).
local e2 = env.parse("Env([0,1,0.3,0], [0.1,0.2,0.5], [\\exp, -4, \\lin])")
if not (e2 and e2.points[2].c == "exp" and e2.points[3].c == -4 and e2.points[4].c == "lin") then
  errors[#errors+1] = "10b: per-segment curve array"
end
local e3 = env.parse("Env([0,1,0.3,0], [0.1,0.2,0.5], \\exp)")
if not (e3 and e3.points[2].c == "exp" and e3.points[4].c == "exp") then errors[#errors+1] = "10b: scalar applies to all" end

-- 10c: the curve actually changes the render — convex (-4) ≠ linear (0), and
-- the curved decay sits lower at the segment midpoint (drops faster).
local function rows_text(src)
  local rows = w.env_preview(env.parse(src))
  local out = {}
  for _, row in ipairs(rows) do local s = "" for _, seg in ipairs(row) do s = s .. seg[1] end out[#out+1] = s end
  return table.concat(out, "\n")
end
local lin = rows_text("Env.perc(0.01, 1.2, 1, 0)")
local cv = rows_text("Env.perc(0.01, 1.2, 1, -4)")
if lin == cv then errors[#errors+1] = "10c: curved render identical to linear" end

if #errors == 0 then
  print("ENV_RESULT:PASS")
else
  for _, e in ipairs(errors) do io.stderr:write("  env error: " .. e .. "\n") end
  print("ENV_RESULT:FAIL")
end
LUAEOF

ENV_RESULT=$(PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
  -c "luafile $TEST_DIR/_tmp_env_test.lua" \
  -c "qa!" 2>&1 | grep "ENV_RESULT:" | head -1 || true)

if [[ "$ENV_RESULT" == *":PASS"* ]]; then
  report "env: curve parsed per segment (default / numeric / symbol)" "PASS"
  report "env: Env.new per-segment curve array (wrapping)" "PASS"
  report "env: curved interpolation bends the plot vs linear" "PASS"
else
  PLUGIN_DIR="$PLUGIN_DIR" nvim --headless --clean -u NONE \
    -c "luafile $TEST_DIR/_tmp_env_test.lua" \
    -c "qa!" 2>&1 | head -30 >&2
  report "Test 10: envelope curves" "FAIL"
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
