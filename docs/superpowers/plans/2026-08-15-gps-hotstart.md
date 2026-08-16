# GPS Hot-Start (UBX-AID-INI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prime the Pager's u-blox 7 GPS dongle with the last known position (and, when the system clock looks sane, the current time) immediately before `gpsd` restarts, so repeat GPS use gets a warm/hot start instead of a blind cold search.

**Architecture:** Two roles duplicated verbatim across three existing payloads (this repo has no shared-library mechanism between payload directories — confirmed, no precedent anywhere in repo history). `gps-checker` and `gps-dashboard` cache every observed fix into a shared `PAYLOAD_SET_CONFIG` namespace. `gps-checker` and `wardrive_activate` read that cache and inject a hand-built `UBX-AID-INI` binary message to the receiver in the gap between stopping and starting `gpsd`.

**Tech Stack:** Bash (payload.sh, matches every other payload in this repo), `jq` for gpsd JSON parsing (already a dependency of `gps-checker`/`gps-dashboard`), `awk` for float scaling, `uci`/`stty`/`service`/`/etc/init.d/gpsd` (all already used by these payloads or their siblings).

## Global Constraints

- Shared cache namespace is `PAYLOAD_NAME="gps_hotstart"`, keys `lat`, `lon`, `alt`, `eph`, `ts` — verbatim, across all three payloads.
- `UBX-AID-INI` field layout, scale factors, and flag bit numbers are fixed by u-blox's protocol spec (GPS.G7-SW-12001-B §34.8.2) and must not be reinterpreted:
  - Payload offsets: `0:lat(I4,deg*1e7) 4:lon(I4,deg*1e7) 8:alt(I4,cm) 12:posAcc(U4,cm) 16:tmCfg(U2)=0 18:wnoOrDate(U2) 20:towOrTime(U4) 24:towNs(I4)=0 28:tAccMs(U4) 32:tAccNs(U4)=0 36:clkDOrFreq(I4)=0 40:clkDAccOrFreqAcc(U4)=0 44:flags(U4)`
  - Flags: bit0 `pos`(0x1), bit1 `time`(0x2), bit5 `lla`(0x20), bit10 `utc`(0x400).
  - `wnoOrDate` = `(year-2000)*100 + month`; `towOrTime` = `day*1000000 + hour*10000 + min*100 + sec` (both only meaningful when the `time`/`utc` flags are set).
  - Frame: `0xB5 0x62` sync + class `0x0B` + id `0x01` + length LE `0x30 0x00` + 48-byte payload + `CK_A CK_B` (standard UBX 8-bit Fletcher checksum over class-through-payload).
- `posAcc` floors at `5000` (50m) when derived from cached `eph`, else flat `300000` (3km) when `eph` is unknown.
- `tAccMs` is always `2000` when the `time` flag is set.
- Time aiding (`time`+`utc` flags) is sent only when `date -u +%Y` is between 2020 and 2035 inclusive — a coarse sanity floor against a clearly-wrong system clock (this device has no RTC/battery backup). Position aiding is sent whenever any cache exists, with no age cutoff.
- Every code path through the injector must end with `gpsd` started — no path may leave it stopped, including every error/skip path.
- No test files are ever committed under `library/` — this repo ships each payload directory as-is to users (confirmed: no `tests/` directory or test file exists anywhere in repo history). All test scripts in this plan live under `/tmp/gps_hotstart_tests/` and are explicitly scratch, never `git add`ed.
- Golden test vector (independently computed with Python's `struct` module, not hand-derived — see Task 1) for inputs `lat=33.4488935 lon=-86.9114626 alt=200.5m eph=12.3m` captured at `2026-08-15T23:05:33Z`:
  - `lat_e7=334488935 lon_e7=-869114626 alt_cm=20050 pos_acc_cm=5000 wno_or_date=2608 tow_or_time=15230533 flags=0x423(1059)`
  - 48-byte payload as decimal bytes: `103 229 239 19 254 92 50 204 82 78 0 0 136 19 0 0 0 0 48 10 69 102 232 0 0 0 0 0 208 7 0 0 0 0 0 0 0 0 0 0 0 0 0 0 35 4 0 0`
  - Full 56-byte frame, hex: `b5620b01300067e5ef13fe5c32cc524e0000881300000000300a4566e80000000000d007000000000000000000000000000023040000e8d7`
  - Trivial second vector (empty-payload `AID-INI` poll, class `0x0B` id `0x01` length `0`): checksum bytes `12 47` (decimal) / `0x0C 0x2F`.

---

## Task 1: Core UBX-AID-INI helpers + writer/injector wiring in gps-checker

This is the reference implementation: every function the other two payloads
will copy verbatim gets written, tested, and wired up here first, in the
payload that plays both roles (writer + injector).

**Files:**
- Modify: `library/user/general/gps-checker/payload.sh`
- Test (scratch, not committed): `/tmp/gps_hotstart_tests/test_gps_checker.sh`

**Interfaces:**
- Produces (consumed verbatim by Tasks 2 and 3):
  - `HOTSTART_NS` — the string `"gps_hotstart"`.
  - `_ubx_append_le VAL NBYTES` — appends `NBYTES` little-endian bytes of
    integer `VAL` (signed or unsigned, two's-complement-wrapped if negative)
    to the global array `_ubx_payload_bytes`.
  - `ubx_u2 VAL` / `ubx_u4 VAL` / `ubx_i4 VAL` — thin wrappers over
    `_ubx_append_le` for 2-byte and 4-byte fields (identical encoding
    regardless of signedness; the names exist for field-table readability).
  - `ubx_checksum BYTE...` — takes decimal byte values as positional args,
    echoes `"CK_A CK_B"` (decimal).
  - `build_aid_ini LAT_E7 LON_E7 ALT_CM POS_ACC_CM WNO_OR_DATE TOW_OR_TIME T_ACC_MS FLAGS`
    — populates global arrays `_ubx_payload_bytes` (48 decimal byte values)
    and `_ubx_frame_bytes` (56 decimal byte values, the full wire frame).
    Returns 1 (and prints an error to stderr) if the payload isn't exactly
    48 bytes; returns 0 otherwise.
  - `ubx_write_frame DEVICE` — writes `_ubx_frame_bytes` as raw bytes to
    `DEVICE` (a path — a real char device on the Pager, or a plain file in
    tests).
  - `resolve_gps_device` — echoes the resolved (symlink-followed) character
    device path from `uci gpsd.core.device`, or returns 1 if unset/invalid.
  - `cache_fix LAT LON ALT EPH` — writes the four values plus
    `ts=$(date -u +%s)` into the `gps_hotstart` `PAYLOAD_SET_CONFIG`
    namespace. No-op if `LAT` or `LON` is empty.
  - `inject_hotstart DEVICE` — reads the cache, decides flags/time fields,
    calls `build_aid_ini`, sets the line speed, and writes the frame to
    `DEVICE`. Returns 1 (no-op, caller must still restart gpsd normally) on
    any missing/invalid input; returns 0 on a completed write attempt.

- [ ] **Step 1: Add the `BASH_SOURCE` guard around the existing main flow**

`gps-checker/payload.sh` currently runs `run_check` and its input loop
unconditionally at the bottom of the file (lines 103-124), which would fire
`LOG`/`WAIT_FOR_INPUT` — and `exit`, which terminates the *sourcing* shell
too — the moment a test harness sources it. Do this first, before writing
any test that sources the file. Wrap the existing block in the same
source-guard pattern `gps-dashboard/payload.sh` already uses. Replace:

```bash
run_check

while true; do
    LOG ""
    LOG cyan "Press [▲] to check again"
    LOG red "Press [▼] to exit"
    choice=$(WAIT_FOR_INPUT)
    if [ "$choice" = "UP" ]; then
        run_check
    else
        LOG "Exiting."
        break
    fi
done

# Only the "gpsd produced nothing" case is treated as a payload failure -
# the Pager flags any non-zero exit as an execution error, and STATUS 2
# (still acquiring / no fix yet) is a normal diagnostic outcome, not an error.
if [ "$STATUS" = "1" ]; then
    exit 1
fi
exit 0
```

with:

```bash
# Only run the interactive flow when executed directly, not when sourced -
# lets tests source it for the function definitions without triggering the
# real loop (same pattern gps-dashboard/payload.sh uses).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    run_check

    while true; do
        LOG ""
        LOG cyan "Press [▲] to check again"
        LOG red "Press [▼] to exit"
        choice=$(WAIT_FOR_INPUT)
        if [ "$choice" = "UP" ]; then
            run_check
        else
            LOG "Exiting."
            break
        fi
    done

    # Only the "gpsd produced nothing" case is treated as a payload failure -
    # the Pager flags any non-zero exit as an execution error, and STATUS 2
    # (still acquiring / no fix yet) is a normal diagnostic outcome, not an
    # error.
    if [ "$STATUS" = "1" ]; then
        exit 1
    fi
    exit 0
fi
```

- [ ] **Step 2: Write the failing tests**

Create `/tmp/gps_hotstart_tests/test_gps_checker.sh`:

```bash
#!/bin/bash
# Scratch test harness for gps-checker's hot-start functions. Not committed
# to the repo - this repo ships payload directories as-is to users, so no
# test files belong under library/.
set -u
FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=1
    else
        echo "PASS: $desc"
    fi
}

# --- Shim every DuckyScript / system command payload.sh's top level or
# sourced functions might touch, BEFORE sourcing, so sourcing is side-effect
# free and never blocks. ---
LOG() { :; }
WAIT_FOR_INPUT() { echo "DOWN"; }
START_SPINNER() { echo "spinner1"; }
STOP_SPINNER() { :; }

declare -A _FAKE_CONFIG=()
PAYLOAD_GET_CONFIG() { echo "${_FAKE_CONFIG[$1:$2]:-}"; }
PAYLOAD_SET_CONFIG() { _FAKE_CONFIG["$1:$2"]="$3"; }

_FAKE_UCI_DEVICE=""
_FAKE_UCI_SPEED="115200"
uci() {
    if [ "$2" = "get" ] && [ "$3" = "gpsd.core.device" ]; then
        echo "$_FAKE_UCI_DEVICE"
    elif [ "$2" = "get" ] && [ "$3" = "gpsd.core.speed" ]; then
        echo "$_FAKE_UCI_SPEED"
    fi
}
service() { :; }
stty() { :; }
gpspipe() { :; }
timeout() { shift; "$@"; }

# --- Source the payload for its function definitions only. The
# BASH_SOURCE guard added in Step 3 keeps the real run_check/while-loop
# from executing here. ---
source /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-checker/payload.sh

echo "== ubx_checksum =="
read -r ck_a ck_b <<< "$(ubx_checksum 11 1 0 0)"
assert_eq "empty AID-INI poll checksum CK_A" "12" "$ck_a"
assert_eq "empty AID-INI poll checksum CK_B" "47" "$ck_b"

echo "== _ubx_append_le / ubx_i4 two's complement =="
_ubx_payload_bytes=()
ubx_i4 -1
assert_eq "ubx_i4 -1 byte count" "4" "${#_ubx_payload_bytes[@]}"
assert_eq "ubx_i4 -1 bytes" "255 255 255 255" "${_ubx_payload_bytes[*]}"

echo "== build_aid_ini golden vector =="
build_aid_ini 334488935 -869114626 20050 5000 2608 15230533 2000 1059
assert_eq "payload byte count" "48" "${#_ubx_payload_bytes[@]}"
assert_eq "payload bytes" \
  "103 229 239 19 254 92 50 204 82 78 0 0 136 19 0 0 0 0 48 10 69 102 232 0 0 0 0 0 208 7 0 0 0 0 0 0 0 0 0 0 0 0 0 0 35 4 0 0" \
  "${_ubx_payload_bytes[*]}"
assert_eq "frame byte count" "56" "${#_ubx_frame_bytes[@]}"
frame_hex="$(printf '%02x' "${_ubx_frame_bytes[@]}")"
assert_eq "frame hex" \
  "b5620b01300067e5ef13fe5c32cc524e0000881300000000300a4566e80000000000d007000000000000000000000000000023040000e8d7" \
  "$frame_hex"

echo "== ubx_write_frame roundtrip =="
build_aid_ini 334488935 -869114626 20050 5000 2608 15230533 2000 1059
tmpfile="$(mktemp)"
ubx_write_frame "$tmpfile"
written_hex="$(od -An -v -tx1 "$tmpfile" | tr -d ' \n')"
assert_eq "written frame hex matches" \
  "b5620b01300067e5ef13fe5c32cc524e0000881300000000300a4566e80000000000d007000000000000000000000000000023040000e8d7" \
  "$written_hex"
rm -f "$tmpfile"

echo "== resolve_gps_device =="
_FAKE_UCI_DEVICE=""
if resolve_gps_device >/dev/null 2>&1; then
    echo "FAIL: resolve_gps_device should fail with no UCI device set"; FAIL=1
else
    echo "PASS: resolve_gps_device fails cleanly with no UCI device set"
fi
realdev="$(mktemp)"
_FAKE_UCI_DEVICE="$realdev"
# resolve_gps_device requires a character device (-c); a regular file isn't
# one, so this should still fail cleanly rather than crash.
if resolve_gps_device >/dev/null 2>&1; then
    echo "FAIL: resolve_gps_device should fail for a non-char-device path"; FAIL=1
else
    echo "PASS: resolve_gps_device fails cleanly for a non-char-device path"
fi
rm -f "$realdev"

echo "== cache_fix =="
_FAKE_CONFIG=()
cache_fix "" "-86.9" "200" "12"
assert_eq "cache_fix no-ops on empty lat" "" "${_FAKE_CONFIG[gps_hotstart:lat]:-}"
cache_fix "33.4488935" "-86.9114626" "200.5" "12.3"
assert_eq "cache_fix stores lat" "33.4488935" "${_FAKE_CONFIG[gps_hotstart:lat]}"
assert_eq "cache_fix stores lon" "-86.9114626" "${_FAKE_CONFIG[gps_hotstart:lon]}"
assert_eq "cache_fix stores alt" "200.5" "${_FAKE_CONFIG[gps_hotstart:alt]}"
assert_eq "cache_fix stores eph" "12.3" "${_FAKE_CONFIG[gps_hotstart:eph]}"
[ -n "${_FAKE_CONFIG[gps_hotstart:ts]:-}" ] && echo "PASS: cache_fix stores a ts" || { echo "FAIL: cache_fix ts missing"; FAIL=1; }

echo "== inject_hotstart: no cache => no-op =="
_FAKE_CONFIG=()
if inject_hotstart "/dev/null"; then
    echo "FAIL: inject_hotstart should return 1 with no cache"; FAIL=1
else
    echo "PASS: inject_hotstart returns 1 with no cache"
fi

echo "== inject_hotstart: cache present, writes a frame, clock-sane includes time flags =="
_FAKE_CONFIG=()
cache_fix "33.4488935" "-86.9114626" "200.5" "12.3"
outfile="$(mktemp)"
date() { command date -u +%Y%m%d%H%M%S 2>/dev/null | { command -v : ; }; }
unset -f date
inject_hotstart "$outfile"
rc=$?
assert_eq "inject_hotstart return code with usable cache" "0" "$rc"
written_len="$(wc -c < "$outfile")"
assert_eq "inject_hotstart wrote a 56-byte frame" "56" "$written_len"
first_bytes="$(od -An -v -tx1 -N4 "$outfile" | tr -d ' \n')"
assert_eq "frame starts with sync+class+id" "b5620b01" "$first_bytes"
flags_bytes="$(od -An -v -tx1 -j 50 -N4 "$outfile" | tr -d ' \n')"
year_now="$(date -u +%Y)"
if [ "$year_now" -ge 2020 ] && [ "$year_now" -le 2035 ]; then
    assert_eq "flags include time+utc when clock is sane" "23040000" "$flags_bytes"
else
    assert_eq "flags omit time+utc when clock looks wrong" "21000000" "$flags_bytes"
fi
rm -f "$outfile"

echo "== inject_hotstart: malformed cache => no-op =="
_FAKE_CONFIG=()
_FAKE_CONFIG["gps_hotstart:lat"]="not-a-number"
_FAKE_CONFIG["gps_hotstart:lon"]="-86.9"
if inject_hotstart "/dev/null"; then
    echo "FAIL: inject_hotstart should reject non-numeric lat"; FAIL=1
else
    echo "PASS: inject_hotstart rejects non-numeric lat"
fi

echo "== inject_hotstart: wnoOrDate/towOrTime packing against a fixed date =="
# Reuses the exact lat/lon/alt/eph AND date the golden vector in Global
# Constraints was computed for (2026-08-15T23:05:33Z), so if this test
# passes, the calendar -> YYMM/DDHHMMSS packing arithmetic inside
# inject_hotstart (not just build_aid_ini's byte-packing of an
# already-given wno/tow, tested above) is proven correct end-to-end.
_FAKE_CONFIG=()
_FAKE_CONFIG["gps_hotstart:lat"]="33.4488935"
_FAKE_CONFIG["gps_hotstart:lon"]="-86.9114626"
_FAKE_CONFIG["gps_hotstart:alt"]="200.5"
_FAKE_CONFIG["gps_hotstart:eph"]="12.3"
date() {
    case "$1 $2" in
        "-u +%Y") echo "2026" ;;
        "-u +%m") echo "08" ;;
        "-u +%d") echo "15" ;;
        "-u +%H") echo "23" ;;
        "-u +%M") echo "05" ;;
        "-u +%S") echo "33" ;;
        "-u +%s") echo "1786921533" ;;
        *) command date "$@" ;;
    esac
}
outfile2="$(mktemp)"
inject_hotstart "$outfile2"
frame_hex2="$(od -An -v -tx1 "$outfile2" | tr -d ' \n')"
assert_eq "frame matches golden vector under fixed date 2026-08-15T23:05:33Z" \
  "b5620b01300067e5ef13fe5c32cc524e0000881300000000300a4566e80000000000d007000000000000000000000000000023040000e8d7" \
  "$frame_hex2"
rm -f "$outfile2"
unset -f date

if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$FAIL"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bash /tmp/gps_hotstart_tests/test_gps_checker.sh`

Expected: fails immediately — `payload.sh` doesn't yet define `ubx_checksum`,
`build_aid_ini`, `cache_fix`, `inject_hotstart`, etc. (a "command not found"
or similar error, not a clean PASS/FAIL report). The guard added in Step 1
means this fails fast on the missing functions rather than running the real
`run_check`/input-loop flow.

- [ ] **Step 4: Add the hot-start functions**

Insert this block into `gps-checker/payload.sh` after the `SAMPLE_SECS=6`
line and before `restart_gpsd()`:

```bash
# --- GPS hot-start (UBX-AID-INI) ----------------------------------------
# Shared PAYLOAD_SET_CONFIG/PAYLOAD_GET_CONFIG namespace used by
# gps-checker, gps-dashboard, and wardrive_activate to cache the last known
# GPS fix and prime the u-blox 7 receiver for a faster next start. Field
# layout, scale factors, and flag bits verified against u-blox's
# GPS.G7-SW-12001-B protocol spec, section 34.8.2.
HOTSTART_NS="gps_hotstart"

# Appends the little-endian bytes of a signed/unsigned N-byte integer to
# the global _ubx_payload_bytes array. Handles negative values via two's
# complement - encoding is identical for signed and unsigned fields once
# wrapped, so this one function backs both ubx_i4 and ubx_u4.
_ubx_append_le() {
    local val="$1" nbytes="$2" uval i shift_bits byte
    if [ "$val" -lt 0 ]; then
        uval=$(( val + (1 << (nbytes * 8)) ))
    else
        uval=$val
    fi
    for (( i = 0; i < nbytes; i++ )); do
        shift_bits=$(( i * 8 ))
        byte=$(( (uval >> shift_bits) & 0xFF ))
        _ubx_payload_bytes+=("$byte")
    done
}

ubx_u2() { _ubx_append_le "$1" 2; }
ubx_u4() { _ubx_append_le "$1" 4; }
ubx_i4() { _ubx_append_le "$1" 4; }

# UBX 8-bit Fletcher checksum over the given decimal byte values (class,
# id, lenLo, lenHi, payload...). Echoes "CK_A CK_B" as decimal values.
ubx_checksum() {
    local ck_a=0 ck_b=0 b
    for b in "$@"; do
        ck_a=$(( (ck_a + b) & 0xFF ))
        ck_b=$(( (ck_b + ck_a) & 0xFF ))
    done
    echo "$ck_a $ck_b"
}

# Builds a full UBX-AID-INI message from already-resolved field values.
# Sets globals _ubx_payload_bytes (48 decimal byte values) and
# _ubx_frame_bytes (56 decimal byte values - the full wire frame, ready
# for ubx_write_frame). Returns 1 if the payload isn't exactly 48 bytes.
build_aid_ini() {
    local lat_e7="$1" lon_e7="$2" alt_cm="$3" pos_acc_cm="$4" \
          wno_or_date="$5" tow_or_time="$6" t_acc_ms="$7" flags="$8"

    _ubx_payload_bytes=()
    ubx_i4 "$lat_e7"
    ubx_i4 "$lon_e7"
    ubx_i4 "$alt_cm"
    ubx_u4 "$pos_acc_cm"
    ubx_u2 0                 # tmCfg - no external time-pulse hardware
    ubx_u2 "$wno_or_date"
    ubx_u4 "$tow_or_time"
    ubx_i4 0                 # towNs - no sub-second precision available
    ubx_u4 "$t_acc_ms"
    ubx_u4 0                 # tAccNs
    ubx_i4 0                 # clkDOrFreq - unused, no drift/freq aiding
    ubx_u4 0                 # clkDAccOrFreqAcc - unused
    ubx_u4 "$flags"

    if [ "${#_ubx_payload_bytes[@]}" -ne 48 ]; then
        echo "build_aid_ini: internal error, payload is ${#_ubx_payload_bytes[@]} bytes, expected 48" >&2
        return 1
    fi

    local covered=(11 1 48 0 "${_ubx_payload_bytes[@]}")  # class 0x0B, id 0x01, length 48 (LE 0x0030)
    local ck_a ck_b
    read -r ck_a ck_b <<< "$(ubx_checksum "${covered[@]}")"

    _ubx_frame_bytes=(181 98 "${covered[@]}" "$ck_a" "$ck_b")  # 181 98 = 0xB5 0x62 sync
}

# Writes the global _ubx_frame_bytes array as raw bytes to $1. Builds a
# backslash-octal escape string in plain bash concatenation (not via a
# printf format-string %-conversion, which can't parameterize \NNN
# escapes), then lets one final printf interpret those escapes into bytes -
# this is what correctly handles embedded zero bytes (e.g. tmCfg=0x0000),
# which this message has several of.
ubx_write_frame() {
    local device="$1" b oct fmt=""
    for b in "${_ubx_frame_bytes[@]}"; do
        oct="$(printf '%03o' "$b")"
        fmt="${fmt}\\${oct}"
    done
    printf "$fmt" > "$device"
}

# Resolves the UCI-configured GPS device to its real character-device path,
# following the /dev/serial/by-path symlink UCI usually stores there.
resolve_gps_device() {
    local device
    device="$(uci -q get gpsd.core.device)"
    [ -n "$device" ] || return 1
    if [ -L "$device" ]; then
        device="$(readlink -f "$device")"
    fi
    [ -c "$device" ] || return 1
    echo "$device"
}

# Caches the last known fix for the next hot-start injection. No-op if lat
# or lon is empty (nothing usable to cache).
cache_fix() {
    local lat="$1" lon="$2" alt="$3" eph="$4"
    [ -n "$lat" ] && [ -n "$lon" ] || return
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "lat" "$lat" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "lon" "$lon" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "alt" "$alt" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "eph" "$eph" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "ts" "$(date -u +%s)" >/dev/null 2>&1
}

# Reads the cached fix (if any) and injects UBX-AID-INI to $1 (a resolved
# device path) at the configured baud. Returns 1 (no-op) if there's no
# usable cache, an invalid device, or the write fails - callers must
# proceed to a normal gpsd start regardless of this function's return
# code; this feature must never leave gpsd stopped.
inject_hotstart() {
    local device="$1"

    local lat lon alt eph
    lat="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "lat" 2>/dev/null)"
    lon="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "lon" 2>/dev/null)"
    alt="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "alt" 2>/dev/null)"
    eph="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "eph" 2>/dev/null)"

    case "$lat" in ''|*[!0-9.-]*) return 1 ;; esac
    case "$lon" in ''|*[!0-9.-]*) return 1 ;; esac
    [ -n "$device" ] || return 1

    local lat_e7 lon_e7 alt_cm pos_acc_cm
    lat_e7="$(awk -v v="$lat" 'BEGIN { printf "%.0f", v * 10000000 }')"
    lon_e7="$(awk -v v="$lon" 'BEGIN { printf "%.0f", v * 10000000 }')"
    case "$alt" in ''|*[!0-9.-]*) alt_cm=0 ;; *) alt_cm="$(awk -v v="$alt" 'BEGIN { printf "%.0f", v * 100 }')" ;; esac
    case "$eph" in
        ''|*[!0-9.-]*) pos_acc_cm=300000 ;;
        *)
            pos_acc_cm="$(awk -v v="$eph" 'BEGIN { printf "%.0f", v * 100 }')"
            [ "$pos_acc_cm" -lt 5000 ] && pos_acc_cm=5000
            ;;
    esac

    local flags=$((0x1 | 0x20))   # pos + lla
    local wno_or_date=0 tow_or_time=0 t_acc_ms=0
    local year
    year="$(date -u +%Y)"
    if [ "$year" -ge 2020 ] 2>/dev/null && [ "$year" -le 2035 ] 2>/dev/null; then
        flags=$((flags | 0x2 | 0x400))   # time + utc
        local month day hour min sec
        month="$(date -u +%m)"; month=$((10#$month))
        day="$(date -u +%d)"; day=$((10#$day))
        hour="$(date -u +%H)"; hour=$((10#$hour))
        min="$(date -u +%M)"; min=$((10#$min))
        sec="$(date -u +%S)"; sec=$((10#$sec))
        wno_or_date=$(( (year - 2000) * 100 + month ))
        tow_or_time=$(( day * 1000000 + hour * 10000 + min * 100 + sec ))
        t_acc_ms=2000
    fi

    build_aid_ini "$lat_e7" "$lon_e7" "$alt_cm" "$pos_acc_cm" \
                  "$wno_or_date" "$tow_or_time" "$t_acc_ms" "$flags" || return 1

    [ -c "$device" ] || [ -f "$device" ] || return 1
    local baud
    baud="$(uci -q get gpsd.core.speed)"
    [ -n "$baud" ] && stty -F "$device" "$baud" raw 2>/dev/null

    ubx_write_frame "$device" 2>/dev/null || return 1
    return 0
}
```

- [ ] **Step 5: Wire `cache_fix` into `show_coordinates`**

Replace the existing `show_coordinates` function body:

```bash
show_coordinates() {
    tpv_json="$(timeout 5 gpspipe -w -n 40 2>/dev/null | grep '"class":"TPV"' | tail -n 1)"
    lat="$(echo "$tpv_json" | jq -r '.lat // empty' 2>/dev/null)"
    lon="$(echo "$tpv_json" | jq -r '.lon // empty' 2>/dev/null)"
    if [ -z "$lat" ] || [ -z "$lon" ]; then
        LOG yellow "Fix reported, but coordinates aren't available yet - try again shortly."
        return
    fi
    alt="$(echo "$tpv_json" | jq -r '.altMSL // .alt // "n/a"' 2>/dev/null)"
    eph="$(echo "$tpv_json" | jq -r '.eph // "n/a"' 2>/dev/null)"
    LOG green "Lat: $lat  Lon: $lon"
    LOG green "Alt: ${alt}m   Accuracy: ~${eph}m"
}
```

with:

```bash
show_coordinates() {
    tpv_json="$(timeout 5 gpspipe -w -n 40 2>/dev/null | grep '"class":"TPV"' | tail -n 1)"
    lat="$(echo "$tpv_json" | jq -r '.lat // empty' 2>/dev/null)"
    lon="$(echo "$tpv_json" | jq -r '.lon // empty' 2>/dev/null)"
    if [ -z "$lat" ] || [ -z "$lon" ]; then
        LOG yellow "Fix reported, but coordinates aren't available yet - try again shortly."
        return
    fi
    alt="$(echo "$tpv_json" | jq -r '.altMSL // .alt // "n/a"' 2>/dev/null)"
    eph="$(echo "$tpv_json" | jq -r '.eph // "n/a"' 2>/dev/null)"
    LOG green "Lat: $lat  Lon: $lon"
    LOG green "Alt: ${alt}m   Accuracy: ~${eph}m"

    # Cache this fix for the next gpsd restart's hot-start injection - uses
    # its own "empty" defaults (not the "n/a" display placeholders above).
    local cache_alt cache_eph
    cache_alt="$(echo "$tpv_json" | jq -r '.altMSL // .alt // empty' 2>/dev/null)"
    cache_eph="$(echo "$tpv_json" | jq -r '.eph // empty' 2>/dev/null)"
    cache_fix "$lat" "$lon" "$cache_alt" "$cache_eph"
}
```

- [ ] **Step 6: Wire `inject_hotstart` into `restart_gpsd`**

Replace:

```bash
restart_gpsd() {
    LOG yellow "Restarting gpsd..."
    service gpsd restart
    sleep 2
}
```

with:

```bash
restart_gpsd() {
    LOG yellow "Restarting gpsd..."
    local device
    if device="$(resolve_gps_device)"; then
        service gpsd stop
        inject_hotstart "$device"
        service gpsd start
    else
        service gpsd restart
    fi
    sleep 2
}
```

- [ ] **Step 7: Bump the version comment**

Change the header block's `# Version: 2.0` to `# Version: 2.1` and extend
the `# Description:` line to mention the new behavior:

```bash
# Description: Diagnoses GPS status step by step - data flow, satellite detection, nav decode, and fix - and explains the likely cause at each stage. Caches fixes and primes the receiver for a faster next start.
# Version: 2.1
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bash /tmp/gps_hotstart_tests/test_gps_checker.sh`

Expected: every line prints `PASS:`, final line `ALL TESTS PASSED`, exit
code `0`.

- [ ] **Step 9: `bash -n` syntax check**

Run: `bash -n library/user/general/gps-checker/payload.sh`

Expected: no output, exit code `0`.

- [ ] **Step 10: Update the README**

Append to `library/user/general/gps-checker/README.md` (create a "Hot-start
caching" section near the end of the existing content):

```markdown
## Hot-start caching

Every fix this payload observes is cached (position, altitude, accuracy,
capture time). The next time this payload restarts gpsd, it primes the
u-blox receiver with that cached fix (`UBX-AID-INI`) first, which can
noticeably cut time-to-first-fix compared to a blind cold start. This is
fully automatic - no setup, no new menu options. If there's no cache yet
(first run) or anything about it looks wrong, this is skipped silently and
gpsd restarts normally.
```

- [ ] **Step 11: Commit**

```bash
git add library/user/general/gps-checker/payload.sh library/user/general/gps-checker/README.md
git commit -m "$(cat <<'EOF'
Add GPS hot-start (UBX-AID-INI) to gps-checker

Caches every observed fix and primes the u-blox 7 receiver with the
last known position/time before each gpsd restart, cutting
time-to-first-fix on repeat use. Byte layout verified against
u-blox's GPS.G7-SW-12001-B protocol spec section 34.8.2. Any missing
or invalid cache falls through to today's plain restart - this can
never leave gpsd stopped or block the payload's normal flow.
EOF
)"
```

---

## Task 2: Cache-writing in gps-dashboard

`gps-dashboard` never restarts gpsd itself, so it only needs the writer
half. `cache_fix`'s implementation must be byte-identical to Task 1's (per
Global Constraints — no shared library exists, so this is a deliberate,
tracked duplication).

**Files:**
- Modify: `library/user/general/gps-dashboard/payload.sh`
- Test (scratch, not committed): `/tmp/gps_hotstart_tests/test_gps_dashboard.sh`

**Interfaces:**
- Consumes: none from Task 1 (separate file, no cross-file sourcing between
  payload directories on this platform).
- Produces: `HOTSTART_NS`, `cache_fix` (same names/behavior as Task 1, for
  Task 4's cross-file consistency check).

- [ ] **Step 1: Write the failing test**

Create `/tmp/gps_hotstart_tests/test_gps_dashboard.sh`:

```bash
#!/bin/bash
# Scratch test harness for gps-dashboard's hot-start cache-writing. Not
# committed - see test_gps_checker.sh for why.
set -u
FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $desc"; echo "  expected: $expected"; echo "  actual:   $actual"
        FAIL=1
    else
        echo "PASS: $desc"
    fi
}

LOG() { :; }
declare -A _FAKE_CONFIG=()
PAYLOAD_GET_CONFIG() { echo "${_FAKE_CONFIG[$1:$2]:-}"; }
PAYLOAD_SET_CONFIG() { _FAKE_CONFIG["$1:$2"]="$3"; }
WAIT_FOR_BUTTON_PRESS() { sleep "$2" 2>/dev/null; return 124; }

source /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh

echo "== cache_fix exists and behaves like gps-checker's =="
_FAKE_CONFIG=()
cache_fix "" "-86.9" "200" "12"
assert_eq "cache_fix no-ops on empty lat" "" "${_FAKE_CONFIG[gps_hotstart:lat]:-}"
cache_fix "33.4488935" "-86.9114626" "200.5" "12.3"
assert_eq "cache_fix stores lat" "33.4488935" "${_FAKE_CONFIG[gps_hotstart:lat]}"
assert_eq "cache_fix stores lon" "-86.9114626" "${_FAKE_CONFIG[gps_hotstart:lon]}"

echo "== format_block caches on a fix, does not on no-fix =="
_FAKE_CONFIG=()
raw_fix='{"class":"TPV","mode":3,"lat":33.4488935,"lon":-86.9114626,"altMSL":200.5,"eph":12.3,"time":"2026-08-15T23:05:33.000Z"}
{"class":"DEVICES","devices":[{"path":"/dev/ttyACM0"}]}'
format_block "$raw_fix" >/dev/null
assert_eq "format_block(fix) caches lat" "33.4488935" "${_FAKE_CONFIG[gps_hotstart:lat]:-}"
assert_eq "format_block(fix) caches lon" "-86.9114626" "${_FAKE_CONFIG[gps_hotstart:lon]:-}"

_FAKE_CONFIG=()
raw_nofix='{"class":"TPV","mode":1}
{"class":"DEVICES","devices":[{"path":"/dev/ttyACM0"}]}'
format_block "$raw_nofix" >/dev/null
assert_eq "format_block(no fix) does not cache" "" "${_FAKE_CONFIG[gps_hotstart:lat]:-}"

if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$FAIL"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash /tmp/gps_hotstart_tests/test_gps_dashboard.sh`

Expected: fails — `cache_fix` isn't defined yet in `gps-dashboard/payload.sh`.

- [ ] **Step 3: Add `HOTSTART_NS` and `cache_fix`**

Insert this block into `gps-dashboard/payload.sh` immediately after the
`GNSS_NAMES=(...)` line:

```bash
# --- GPS hot-start cache-writing --------------------------------------
# Shared PAYLOAD_SET_CONFIG namespace also used by gps-checker and
# wardrive_activate to prime the receiver for a faster next start. This
# payload only writes the cache (it never restarts gpsd itself); see
# gps-checker/payload.sh for the paired injector implementation and the
# full byte-layout rationale (u-blox GPS.G7-SW-12001-B protocol spec
# section 34.8.2). Keep this function byte-identical to the copies in
# gps-checker and wardrive_activate - no shared library exists between
# payload directories on this platform.
HOTSTART_NS="gps_hotstart"

cache_fix() {
    local lat="$1" lon="$2" alt="$3" eph="$4"
    [ -n "$lat" ] && [ -n "$lon" ] || return
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "lat" "$lat" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "lon" "$lon" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "alt" "$alt" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "eph" "$eph" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "ts" "$(date -u +%s)" >/dev/null 2>&1
}
```

- [ ] **Step 4: Call `cache_fix` from `format_block`**

Inside `format_block`, find the block that builds `lat_lon_line`:

```bash
        if [ -n "$lat" ] && [ -n "$lon" ]; then
            lat_lon_line="Lat/Lon: $lat, $lon"
        else
            lat_lon_line="Lat/Lon: -- (pending)"
        fi
```

Replace with:

```bash
        if [ -n "$lat" ] && [ -n "$lon" ]; then
            lat_lon_line="Lat/Lon: $lat, $lon"
            local cache_alt cache_eph
            cache_alt="$(echo "$tpv_json" | jq -r '.altMSL // .alt // empty' 2>/dev/null)"
            cache_eph="$(echo "$tpv_json" | jq -r '.eph // empty' 2>/dev/null)"
            cache_fix "$lat" "$lon" "$cache_alt" "$cache_eph"
        else
            lat_lon_line="Lat/Lon: -- (pending)"
        fi
```

- [ ] **Step 5: Bump the version comment**

Change `# Version: 1.0` to `# Version: 1.1` and extend the description:

```bash
# Description: Live-updating GPS status display: connection/fix state, satellites, position, speed/heading, UTC time. Caches fixes to help the next GPS start go faster.
# Version: 1.1
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash /tmp/gps_hotstart_tests/test_gps_dashboard.sh`

Expected: every line `PASS:`, final line `ALL TESTS PASSED`, exit `0`.

- [ ] **Step 7: `bash -n` syntax check**

Run: `bash -n library/user/general/gps-dashboard/payload.sh`

Expected: no output, exit code `0`.

- [ ] **Step 8: Update the README**

Append to `library/user/general/gps-dashboard/README.md`:

```markdown
## Hot-start caching

Every fix shown here is also cached for `gps-checker` and
`wardrive_activate` to use when they next restart gpsd, priming the
receiver for a faster next start. This payload only writes the cache - it
never restarts gpsd itself.
```

- [ ] **Step 9: Commit**

```bash
git add library/user/general/gps-dashboard/payload.sh library/user/general/gps-dashboard/README.md
git commit -m "$(cat <<'EOF'
Cache GPS fixes from gps-dashboard for hot-start priming

Every fix this payload observes is written to the shared
gps_hotstart cache that gps-checker and wardrive_activate read
before their next gpsd restart. Write-only here - this payload
never restarts gpsd itself.
EOF
)"
```

---

## Task 3: Injection wiring in wardrive_activate

`wardrive_activate` never polls a fix itself, so it only needs the injector
half. Unlike `gps-checker`, it already has a validated device path in
`$selected_device` by the time it restarts gpsd (checked earlier in the
script with `-c`), so it doesn't need its own copy of `resolve_gps_device`.

**Files:**
- Modify: `library/user/general/wardrive_activate/payload.sh`
- Test (scratch, not committed): `/tmp/gps_hotstart_tests/test_wardrive_activate.sh`

**Interfaces:**
- Consumes: none from Tasks 1/2 (separate file).
- Produces: `HOTSTART_NS`, `_ubx_append_le`, `ubx_u2`/`ubx_u4`/`ubx_i4`,
  `ubx_checksum`, `build_aid_ini`, `ubx_write_frame`, `inject_hotstart` —
  same names/behavior as Task 1's copies, minus `cache_fix` and
  `resolve_gps_device` (not needed here).

- [ ] **Step 1: Write the failing test**

Create `/tmp/gps_hotstart_tests/test_wardrive_activate.sh`:

```bash
#!/bin/bash
# Scratch test harness for wardrive_activate's hot-start injection. Not
# committed - see test_gps_checker.sh for why.
set -u
FAIL=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $desc"; echo "  expected: $expected"; echo "  actual:   $actual"
        FAIL=1
    else
        echo "PASS: $desc"
    fi
}

LOG() { :; }
ALERT() { :; }
ERROR_DIALOG() { :; }
PROMPT() { :; }
NUMBER_PICKER() { echo 1; }
TEXT_PICKER() { echo 9600; }
CONFIRMATION_DIALOG() { echo 1; }
GPS_LIST() { :; }
GPS_CONFIGURE() { :; }
WIGLE_START() { echo "/root/loot/wigle/test.csv"; }
declare -A _FAKE_CONFIG=()
PAYLOAD_GET_CONFIG() { echo "${_FAKE_CONFIG[$1:$2]:-}"; }
PAYLOAD_SET_CONFIG() { _FAKE_CONFIG["$1:$2"]="$3"; }
uci() { :; }
service() { :; }
stty() { :; }

# Source for function definitions only - wardrive_activate's main flow runs
# unconditionally (no BASH_SOURCE guard, and it isn't needed: the injector
# functions we're testing are plain function definitions above the main
# flow, and `source` in bash still defines every function it encounters
# before executing top-level statements only once it reaches them - but
# wardrive_activate's main flow starts immediately and would run during
# sourcing. So this harness instead extracts and sources ONLY the function
# definitions block via sed, stopping before "LOG "Detecting GPS devices...".
sed -n '1,/^LOG "Detecting GPS devices/p' \
    /Users/eighmy/repos/PineapplePager/payloads/library/user/general/wardrive_activate/payload.sh \
    | sed '$d' > /tmp/gps_hotstart_tests/_wardrive_functions_only.sh
source /tmp/gps_hotstart_tests/_wardrive_functions_only.sh

echo "== build_aid_ini golden vector (same as gps-checker's copy) =="
build_aid_ini 334488935 -869114626 20050 5000 2608 15230533 2000 1059
frame_hex="$(printf '%02x' "${_ubx_frame_bytes[@]}")"
assert_eq "frame hex matches golden vector" \
  "b5620b01300067e5ef13fe5c32cc524e0000881300000000300a4566e80000000000d007000000000000000000000000000023040000e8d7" \
  "$frame_hex"

echo "== inject_hotstart: no cache => returns 1, safe no-op =="
_FAKE_CONFIG=()
if inject_hotstart "/dev/null"; then
    echo "FAIL: inject_hotstart should return 1 with no cache"; FAIL=1
else
    echo "PASS: inject_hotstart returns 1 with no cache"
fi

echo "== inject_hotstart: cache present => writes a 56-byte frame =="
_FAKE_CONFIG["gps_hotstart:lat"]="33.4488935"
_FAKE_CONFIG["gps_hotstart:lon"]="-86.9114626"
_FAKE_CONFIG["gps_hotstart:alt"]="200.5"
_FAKE_CONFIG["gps_hotstart:eph"]="12.3"
outfile="$(mktemp)"
inject_hotstart "$outfile"
rc=$?
assert_eq "inject_hotstart return code" "0" "$rc"
assert_eq "frame length" "56" "$(wc -c < "$outfile")"
rm -f "$outfile"

echo "== inject_hotstart: wnoOrDate/towOrTime packing against a fixed date =="
# Same fixed-date golden-vector check as gps-checker's copy - proves the
# calendar -> YYMM/DDHHMMSS packing arithmetic in *this* duplicated copy
# of inject_hotstart is correct too, not just build_aid_ini's raw
# byte-packing tested above.
date() {
    case "$1 $2" in
        "-u +%Y") echo "2026" ;;
        "-u +%m") echo "08" ;;
        "-u +%d") echo "15" ;;
        "-u +%H") echo "23" ;;
        "-u +%M") echo "05" ;;
        "-u +%S") echo "33" ;;
        "-u +%s") echo "1786921533" ;;
        *) command date "$@" ;;
    esac
}
outfile2="$(mktemp)"
inject_hotstart "$outfile2"
frame_hex2="$(od -An -v -tx1 "$outfile2" | tr -d ' \n')"
assert_eq "frame matches golden vector under fixed date 2026-08-15T23:05:33Z" \
  "b5620b01300067e5ef13fe5c32cc524e0000881300000000300a4566e80000000000d007000000000000000000000000000023040000e8d7" \
  "$frame_hex2"
rm -f "$outfile2"
unset -f date

if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$FAIL"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash /tmp/gps_hotstart_tests/test_wardrive_activate.sh`

Expected: fails — the functions block doesn't exist in
`wardrive_activate/payload.sh` yet, so the `sed` extraction produces an
empty/incomplete file and sourcing defines nothing.

- [ ] **Step 3: Add the hot-start functions**

Insert this block into `wardrive_activate/payload.sh` immediately after the
file header comments (after `# Category: general`) and before the
`# INTERNALS: helpers and device detection` section comment:

```bash
# --- GPS hot-start (UBX-AID-INI) ----------------------------------------
# Shared PAYLOAD_SET_CONFIG/PAYLOAD_GET_CONFIG namespace also used by
# gps-checker and gps-dashboard to cache the last known fix. This payload
# only injects (it doesn't poll fixes itself, so it never writes the
# cache) - see gps-checker/payload.sh for the paired cache_fix writer and
# the full byte-layout rationale (u-blox GPS.G7-SW-12001-B protocol spec
# section 34.8.2). Keep these functions byte-identical to the copies in
# gps-checker and gps-dashboard - no shared library exists between payload
# directories on this platform.
HOTSTART_NS="gps_hotstart"

_ubx_append_le() {
    local val="$1" nbytes="$2" uval i shift_bits byte
    if [ "$val" -lt 0 ]; then
        uval=$(( val + (1 << (nbytes * 8)) ))
    else
        uval=$val
    fi
    for (( i = 0; i < nbytes; i++ )); do
        shift_bits=$(( i * 8 ))
        byte=$(( (uval >> shift_bits) & 0xFF ))
        _ubx_payload_bytes+=("$byte")
    done
}

ubx_u2() { _ubx_append_le "$1" 2; }
ubx_u4() { _ubx_append_le "$1" 4; }
ubx_i4() { _ubx_append_le "$1" 4; }

ubx_checksum() {
    local ck_a=0 ck_b=0 b
    for b in "$@"; do
        ck_a=$(( (ck_a + b) & 0xFF ))
        ck_b=$(( (ck_b + ck_a) & 0xFF ))
    done
    echo "$ck_a $ck_b"
}

build_aid_ini() {
    local lat_e7="$1" lon_e7="$2" alt_cm="$3" pos_acc_cm="$4" \
          wno_or_date="$5" tow_or_time="$6" t_acc_ms="$7" flags="$8"

    _ubx_payload_bytes=()
    ubx_i4 "$lat_e7"
    ubx_i4 "$lon_e7"
    ubx_i4 "$alt_cm"
    ubx_u4 "$pos_acc_cm"
    ubx_u2 0
    ubx_u2 "$wno_or_date"
    ubx_u4 "$tow_or_time"
    ubx_i4 0
    ubx_u4 "$t_acc_ms"
    ubx_u4 0
    ubx_i4 0
    ubx_u4 0
    ubx_u4 "$flags"

    if [ "${#_ubx_payload_bytes[@]}" -ne 48 ]; then
        echo "build_aid_ini: internal error, payload is ${#_ubx_payload_bytes[@]} bytes, expected 48" >&2
        return 1
    fi

    local covered=(11 1 48 0 "${_ubx_payload_bytes[@]}")
    local ck_a ck_b
    read -r ck_a ck_b <<< "$(ubx_checksum "${covered[@]}")"

    _ubx_frame_bytes=(181 98 "${covered[@]}" "$ck_a" "$ck_b")
}

ubx_write_frame() {
    local device="$1" b oct fmt=""
    for b in "${_ubx_frame_bytes[@]}"; do
        oct="$(printf '%03o' "$b")"
        fmt="${fmt}\\${oct}"
    done
    printf "$fmt" > "$device"
}

inject_hotstart() {
    local device="$1"

    local lat lon alt eph
    lat="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "lat" 2>/dev/null)"
    lon="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "lon" 2>/dev/null)"
    alt="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "alt" 2>/dev/null)"
    eph="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "eph" 2>/dev/null)"

    case "$lat" in ''|*[!0-9.-]*) return 1 ;; esac
    case "$lon" in ''|*[!0-9.-]*) return 1 ;; esac
    [ -n "$device" ] || return 1

    local lat_e7 lon_e7 alt_cm pos_acc_cm
    lat_e7="$(awk -v v="$lat" 'BEGIN { printf "%.0f", v * 10000000 }')"
    lon_e7="$(awk -v v="$lon" 'BEGIN { printf "%.0f", v * 10000000 }')"
    case "$alt" in ''|*[!0-9.-]*) alt_cm=0 ;; *) alt_cm="$(awk -v v="$alt" 'BEGIN { printf "%.0f", v * 100 }')" ;; esac
    case "$eph" in
        ''|*[!0-9.-]*) pos_acc_cm=300000 ;;
        *)
            pos_acc_cm="$(awk -v v="$eph" 'BEGIN { printf "%.0f", v * 100 }')"
            [ "$pos_acc_cm" -lt 5000 ] && pos_acc_cm=5000
            ;;
    esac

    local flags=$((0x1 | 0x20))
    local wno_or_date=0 tow_or_time=0 t_acc_ms=0
    local year
    year="$(date -u +%Y)"
    if [ "$year" -ge 2020 ] 2>/dev/null && [ "$year" -le 2035 ] 2>/dev/null; then
        flags=$((flags | 0x2 | 0x400))
        local month day hour min sec
        month="$(date -u +%m)"; month=$((10#$month))
        day="$(date -u +%d)"; day=$((10#$day))
        hour="$(date -u +%H)"; hour=$((10#$hour))
        min="$(date -u +%M)"; min=$((10#$min))
        sec="$(date -u +%S)"; sec=$((10#$sec))
        wno_or_date=$(( (year - 2000) * 100 + month ))
        tow_or_time=$(( day * 1000000 + hour * 10000 + min * 100 + sec ))
        t_acc_ms=2000
    fi

    build_aid_ini "$lat_e7" "$lon_e7" "$alt_cm" "$pos_acc_cm" \
                  "$wno_or_date" "$tow_or_time" "$t_acc_ms" "$flags" || return 1

    [ -c "$device" ] || [ -f "$device" ] || return 1
    local baud
    baud="$(uci -q get gpsd.core.speed)"
    [ -n "$baud" ] && stty -F "$device" "$baud" raw 2>/dev/null

    ubx_write_frame "$device" 2>/dev/null || return 1
    return 0
}

```

- [ ] **Step 4: Wire `inject_hotstart` into the restart step**

Replace:

```bash
LOG "Restarting gpsd..."
# Restart gpsd to apply the new GPS device configuration.
/etc/init.d/gpsd restart
```

with:

```bash
LOG "Restarting gpsd..."
# Restart gpsd to apply the new GPS device configuration, priming the
# receiver with the last known fix first when one is cached (see
# inject_hotstart above) for a faster time-to-first-fix. selected_device
# is already a validated character device by this point (checked above).
/etc/init.d/gpsd stop
inject_hotstart "$selected_device"
/etc/init.d/gpsd start
```

- [ ] **Step 5: Bump the version comment**

Change `# Version: 1.0` to `# Version: 1.1`:

```bash
# Description: Detects GPS devices, configures GPS, and starts Wigle. Primes the receiver with the last known fix for a faster start.
# Version: 1.1
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash /tmp/gps_hotstart_tests/test_wardrive_activate.sh`

Expected: every line `PASS:`, final line `ALL TESTS PASSED`, exit `0`.

- [ ] **Step 7: `bash -n` syntax check**

Run: `bash -n library/user/general/wardrive_activate/payload.sh`

Expected: no output, exit code `0`.

- [ ] **Step 8: Update the README**

Append to `library/user/general/wardrive_activate/README.md`:

```markdown
## Hot-start caching

Before restarting gpsd, this payload primes the receiver with whatever fix
`gps-checker` or `gps-dashboard` most recently cached, for a faster
time-to-first-fix. If there's no cache yet, this is skipped silently and
gpsd restarts normally.
```

- [ ] **Step 9: Commit**

```bash
git add library/user/general/wardrive_activate/payload.sh library/user/general/wardrive_activate/README.md
git commit -m "$(cat <<'EOF'
Inject GPS hot-start (UBX-AID-INI) in wardrive_activate

Primes the u-blox 7 receiver with whatever fix gps-checker or
gps-dashboard most recently cached, before gpsd restarts here. No
cache present falls straight through to a normal restart.
EOF
)"
```

---

## Task 4: On-device verification

Everything above is verified with shimmed unit tests on the development
machine. This task verifies the actual deployed scripts behave correctly
against the real device's bash/awk/busybox userland, without ever writing
untested bytes to the live GPS receiver.

**Files:** none modified — deployment and verification only.

**Interfaces:** none produced — terminal task.

- [ ] **Step 1: Deploy the three updated payloads**

```bash
scp -r library/user/general/gps-checker root@172.16.52.1:/root/payloads/user/general/
scp -r library/user/general/gps-dashboard root@172.16.52.1:/root/payloads/user/general/
scp -r library/user/general/wardrive_activate root@172.16.52.1:/root/payloads/user/general/
ssh root@172.16.52.1 'chmod +x /root/payloads/user/general/gps-checker/payload.sh /root/payloads/user/general/gps-dashboard/payload.sh /root/payloads/user/general/wardrive_activate/payload.sh'
```

Expected: all three `scp` calls complete without error; `chmod` prints
nothing.

- [ ] **Step 2: `bash -n` syntax check on-device**

```bash
ssh root@172.16.52.1 '
bash -n /root/payloads/user/general/gps-checker/payload.sh &&
bash -n /root/payloads/user/general/gps-dashboard/payload.sh &&
bash -n /root/payloads/user/general/wardrive_activate/payload.sh &&
echo SYNTAX_OK
'
```

Expected: prints `SYNTAX_OK`.

- [ ] **Step 3: Re-run the golden-vector test on-device**

The Mac's Python-verified golden vector must also hold under the Pager's
actual mipsel bash/awk — this catches any busybox/mipsel-specific integer
or `awk` behavior the dev-machine tests couldn't. Copy the test harness
over and run it against the deployed copy:

```bash
scp /tmp/gps_hotstart_tests/test_gps_checker.sh root@172.16.52.1:/tmp/
ssh root@172.16.52.1 "sed -i 's#/Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-checker/payload.sh#/root/payloads/user/general/gps-checker/payload.sh#' /tmp/test_gps_checker.sh"
ssh root@172.16.52.1 'bash /tmp/test_gps_checker.sh'
```

Expected: `ALL TESTS PASSED`, exit code `0` — same result as the dev-machine
run in Task 1 Step 8.

- [ ] **Step 4: Confirm the frame writes correctly to a real file on-device**

Before ever pointing this at the live serial device, confirm
`inject_hotstart` produces the right bytes on the real device's filesystem
against a plain file target (already covered by Step 3's test, but this
step additionally confirms it under the real, non-shimmed `date`/`awk`,
using today's actual date rather than the fixed golden-vector date):

```bash
ssh root@172.16.52.1 '
uci set gpsd.core.hotstart_test_lat=33.4488935 2>/dev/null
cat > /tmp/inject_probe.sh <<"PROBE"
source /root/payloads/user/general/gps-checker/payload.sh 2>/dev/null
declare -A _FAKE_CONFIG=(["gps_hotstart:lat"]="33.4488935" ["gps_hotstart:lon"]="-86.9114626" ["gps_hotstart:alt"]="200.5" ["gps_hotstart:eph"]="12.3")
PAYLOAD_GET_CONFIG() { echo "${_FAKE_CONFIG[$1:$2]:-}"; }
inject_hotstart /tmp/probe_frame.bin
echo "rc=$?"
wc -c /tmp/probe_frame.bin
od -An -v -tx1 -N8 /tmp/probe_frame.bin
'
```

Expected: `rc=0`, frame is `56` bytes, and the first 8 bytes are
`b5 62 0b 01 30 00 <2 lat bytes...>` — i.e. valid sync/class/id/length
regardless of the live date used for the time fields.

- [ ] **Step 5: Confirm gpsd survives a stop/inject/start cycle cleanly**

```bash
ssh root@172.16.52.1 '
service gpsd stop
sleep 1
service gpsd start
sleep 2
pgrep gpsd && echo GPSD_RUNNING || echo GPSD_NOT_RUNNING
gpspipe -w -n 3 2>&1 | head -3
'
```

Expected: `GPSD_RUNNING`, and `gpspipe` prints normal `VERSION`/`DEVICES`
JSON lines (confirms `gpsd` reattached to the device correctly after the
stop/start cycle these payloads now perform).

- [ ] **Step 6: Clean up probe artifacts**

```bash
ssh root@172.16.52.1 'rm -f /tmp/probe_frame.bin /tmp/inject_probe.sh /tmp/test_gps_checker.sh; uci -q delete gpsd.core.hotstart_test_lat; uci commit gpsd'
```

Expected: no errors.

- [ ] **Step 7: Note the remaining manual verification**

Record in the task ledger (not a script step — this genuinely needs a
human with the physical dongle, matching the same kind of hands-on-device
caveat already carried by `gps-dashboard`'s own plan): confirming an
actual time-to-first-fix improvement requires clearing the cache
(`PAYLOAD_DEL_CONFIG gps_hotstart lat` etc., or just letting a cold Pager
boot with no prior fix), timing a cold start once, then timing a warm
start immediately after with the same sky view. No agent can perform this
— it needs real satellites, real time elapsed, and a human comparing two
runs.

---

## Out of scope (carried from the design spec)

- No new user-facing payload.
- No GPS week-number/leap-second math (UTC date/time encoding only).
- No clock-drift/frequency aiding.
- No firmware/hotplug-script patching (`/etc/hotplug.d/tty/10-gps`,
  `/etc/init.d/gpsd`) — those are Pager firmware files outside this repo.
- No manual "prime now" payload — priming is fully automatic.
