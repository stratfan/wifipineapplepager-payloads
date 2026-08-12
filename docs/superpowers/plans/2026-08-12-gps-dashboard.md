# GPS Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `library/user/general/gps-dashboard/payload.sh`, a live-refreshing GPS status display (connection/fix status, constellation breakdown, position, speed/heading, UTC time) for the WiFi Pineapple Pager.

**Architecture:** A pure formatting layer (`compass_point`, `format_constellation`, `tpv_mode`, `block_color`, `format_block`) turns one raw `gpspipe -w` JSON sample into display text + a color, fully unit-testable with canned JSON fixtures and no device required. A thin main loop wraps that layer: sample → `LOG` → `timeout 2 WAIT_FOR_BUTTON_PRESS B` → loop or exit. Always exits 0.

**Tech Stack:** Bash, `jq` (parses gpsd JSON), `awk` (one unit conversion), `gpspipe`/`gpsd` (already running on the Pager), Pager DuckyScript commands (`LOG`, `WAIT_FOR_BUTTON_PRESS`).

## Global Constraints

- Payload must **always exit 0**. The Pager's payload runner treats any non-zero exit as an execution error and shows the user a failure banner — confirmed on-device via `logread` while fixing `gps-checker` (`[CRITICAL] [PAYLOAD] Error in payload ... exited with 2`). This payload has no failure state that isn't already communicated via `LOG`, so there is no case where non-zero exit is correct.
- `LOG` requires two arguments: `LOG [color] [message]`. A message may contain embedded newlines inside a single quoted argument (this is how `gps-checker` v1.0 emits multi-line blocks); do not call `LOG` with only one argument — the color is a required positional slot, and the Pager's DuckyScript binaries print usage help instead of erroring cleanly when a required argument is missing (observed with `STOP_SPINNER` earlier in this project).
- `timeout` on this device is GNU coreutils (`/usr/bin/timeout -> /usr/libexec/timeout-coreutils`), confirmed live: `timeout 2 sleep 5` exits `124` (command killed), `timeout 2 true` exits `0` (command finished on its own). The loop-exit design in Task 2 depends on this exact contract.
- `jq` is `1.7.1` on both the Pager and this dev machine — decimal literals round-trip through `jq -r` unchanged (e.g. `33.464887` in → `33.464887` out), confirmed both live on-device (during `gps-checker` work) and by matching local/device `jq --version`. Test fixtures in Task 1 rely on this.
- gpsd JSON field names in use: `TPV.mode` (1/2/3), `TPV.time` (ISO 8601), `TPV.lat`/`TPV.lon`, `TPV.speed` (m/s), `TPV.track` (degrees true), `DEVICES.devices` (array), `SKY.satellites[].gnssid`/`.used`. `gnssid` values follow the u-blox/gpsd convention: `0`=GPS, `1`=SBAS, `2`=Galileo, `3`=BeiDou, `4`=IMES, `5`=QZSS, `6`=GLONASS.
- Repo payload header convention (see any existing `library/user/general/*/payload.sh`):
  ```
  # Title: <name>
  # Description: <one line>
  # Author: <name>
  # Version: <x.y>
  # Category: general
  ```
- This payload only **displays**. It must not attempt to restart gpsd or otherwise "fix" anything — that's `gps-checker`'s job (spec: Out of scope).

---

### Task 1: Pure formatting layer + fixture tests

**Files:**
- Create: `library/user/general/gps-dashboard/payload.sh` (header + functions only, no main loop yet)
- Test (scratch, not committed): `/private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard.sh`

**Interfaces:**
- Produces (consumed by Task 2):
  - `compass_point DEGREES` → echoes an 8-point compass letter (`N`/`NE`/`E`/`SE`/`S`/`SW`/`W`/`NW`)
  - `tpv_mode RAW_JSON_TEXT` → echoes `1`/`2`/`3` (defaults to `1` if no TPV report present)
  - `block_color RAW_JSON_TEXT` → echoes `red` (no data at all) / `yellow` (data but no 3D+ fix... actually mode < 2) / `green` (mode ≥ 2)
  - `format_constellation SKY_JSON_LINE` → echoes one line: `Sats: <breakdown>` or `Sats: none`
  - `format_block RAW_JSON_TEXT` → echoes the full multi-line display block for one sample

- [ ] **Step 1: Write the test fixtures and expected-output assertions**

Create `/private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard.sh`:

```bash
#!/bin/bash
set -u
FAILS=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name"
        echo "--- expected ---"
        echo "$expected"
        echo "--- actual ---"
        echo "$actual"
        FAILS=$((FAILS + 1))
    else
        echo "PASS: $name"
    fi
}

# Fixture A: gpsd unreachable / no data at all
FIXTURE_A=""

# Fixture B: device attached, gpsd up, satellites seen but no fix yet
FIXTURE_B='{"class":"DEVICES","devices":[{"class":"DEVICE","path":"/dev/ttyACM0","driver":"u-blox"}]}
{"class":"SKY","device":"/dev/ttyACM0","satellites":[{"PRN":2,"gnssid":0,"used":false},{"PRN":21,"gnssid":0,"used":false}]}
{"class":"TPV","device":"/dev/ttyACM0","mode":1}'

# Fixture C: 3D fix, multi-constellation
FIXTURE_C='{"class":"DEVICES","devices":[{"class":"DEVICE","path":"/dev/ttyACM0","driver":"u-blox"}]}
{"class":"TPV","device":"/dev/ttyACM0","mode":3,"time":"2026-08-11T02:38:33.000Z","lat":33.464887,"lon":-86.612453,"speed":1.2,"track":184.0}
{"class":"SKY","device":"/dev/ttyACM0","satellites":[{"PRN":2,"gnssid":0,"used":true},{"PRN":4,"gnssid":0,"used":true},{"PRN":7,"gnssid":0,"used":true},{"PRN":8,"gnssid":0,"used":true},{"PRN":9,"gnssid":0,"used":true},{"PRN":14,"gnssid":0,"used":false},{"PRN":16,"gnssid":0,"used":false},{"PRN":26,"gnssid":0,"used":false},{"PRN":65,"gnssid":6,"used":true},{"PRN":66,"gnssid":6,"used":true},{"PRN":75,"gnssid":6,"used":false}]}'

# Fixture D: device attached, gpsd just started, no TPV/SKY reports yet
FIXTURE_D='{"class":"DEVICES","devices":[{"class":"DEVICE","path":"/dev/ttyACM0","driver":"u-blox"}]}'

# Fixture E: gpsd up, no GPS device attached at all
FIXTURE_E='{"class":"VERSION","release":"3.25"}
{"class":"DEVICES","devices":[]}'

check "compass_point 0 = N" "N" "$(compass_point 0)"
check "compass_point 184 = S" "S" "$(compass_point 184)"
check "compass_point 44 = NE" "NE" "$(compass_point 44)"
check "compass_point 350 = N" "N" "$(compass_point 350)"

check "block_color A = red" "red" "$(block_color "$FIXTURE_A")"
check "block_color B = yellow" "yellow" "$(block_color "$FIXTURE_B")"
check "block_color C = green" "green" "$(block_color "$FIXTURE_C")"
check "block_color D = yellow" "yellow" "$(block_color "$FIXTURE_D")"
check "block_color E = yellow" "yellow" "$(block_color "$FIXTURE_E")"

check "format_block A" "gpsd: DOWN" "$(format_block "$FIXTURE_A")"

check "format_block B" "[--] FIX: NO FIX
Lat/Lon: -- (no fix)
Speed: -- Heading: --
Sats: GPS 0/2 used" "$(format_block "$FIXTURE_B")"

check "format_block C" "[2026-08-11 02:38:33 UTC] FIX: 3D
Lat/Lon: 33.464887, -86.612453
Speed: 4.3 km/h  Heading: 184° (S)
Sats: GPS 5/8 used  GLONASS 2/3 used" "$(format_block "$FIXTURE_C")"

check "format_block D" "[--] FIX: NO FIX
Lat/Lon: -- (no fix)
Speed: -- Heading: --
Sats: none" "$(format_block "$FIXTURE_D")"

check "format_block E" "gpsd: UP, no GPS device attached" "$(format_block "$FIXTURE_E")"

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILS FAILURE(S)"
    exit 1
fi
```

- [ ] **Step 2: Run the test harness to confirm it fails (functions don't exist yet)**

Run:
```bash
bash /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard.sh
```
Expected: errors like `compass_point: command not found`, non-zero exit. This confirms the harness actually exercises real function calls rather than trivially passing.

- [ ] **Step 3: Create `library/user/general/gps-dashboard/payload.sh` with the header and the formatting functions**

```bash
#!/bin/bash
# Title: GPS Dashboard
# Description: Live-updating GPS status: connection/fix state, constellation
#   breakdown, position, speed/heading, and UTC time.
# Author: KJ4M
# Version: 1.0
# Category: general

REFRESH_INTERVAL_SECS=2
SAMPLE_TIMEOUT_SECS=3
SAMPLE_LINES=20

GNSS_NAMES=(GPS SBAS Galileo BeiDou IMES QZSS GLONASS)

# Maps a true-north heading in degrees to an 8-point compass letter.
compass_point() {
    local deg="${1%.*}"
    local dirs=(N NE E SE S SW W NW)
    local idx=$(( ((deg % 360 + 360) % 360 + 22) / 45 % 8 ))
    echo "${dirs[$idx]}"
}

# Extracts the fix mode (1=no fix, 2=2D, 3=3D) from the latest TPV report
# in a raw gpspipe -w JSON sample. Defaults to 1 if no TPV report is present.
tpv_mode() {
    local raw="$1"
    local mode
    mode="$(echo "$raw" | grep '"class":"TPV"' | tail -n 1 | jq -r '.mode // 1' 2>/dev/null)"
    echo "${mode:-1}"
}

# Picks a LOG color for a raw sample: red = no data at all, yellow = data
# but no 3D+ fix, green = mode >= 2 (2D or 3D fix).
block_color() {
    local raw="$1"
    if [ -z "$raw" ]; then
        echo "red"
        return
    fi
    local mode
    mode="$(tpv_mode "$raw")"
    if [ "$mode" -ge 2 ] 2>/dev/null; then
        echo "green"
    else
        echo "yellow"
    fi
}

# Groups the satellites in a SKY report by gnssid and formats a one-line
# per-constellation used/seen breakdown, e.g. "Sats: GPS 5/8 used  GLONASS 2/3 used".
format_constellation() {
    local sky="$1"
    if [ -z "$sky" ]; then
        echo "Sats: none"
        return
    fi
    local groups=""
    while read -r gnssid used seen; do
        [ -z "$gnssid" ] && continue
        local name="${GNSS_NAMES[$gnssid]:-GNSS$gnssid}"
        groups+="${groups:+  }${name} ${used}/${seen} used"
    done < <(echo "$sky" | jq -r '
        .satellites // [] | group_by(.gnssid) |
        map({gnssid: .[0].gnssid, seen: length, used: (map(select(.used == true)) | length)}) |
        .[] | "\(.gnssid) \(.used) \(.seen)"
    ' 2>/dev/null)
    [ -z "$groups" ] && groups="none"
    echo "Sats: $groups"
}

# Turns one raw gpspipe -w JSON sample into the full multi-line display block.
format_block() {
    local raw="$1"

    if [ -z "$raw" ]; then
        echo "gpsd: DOWN"
        return
    fi

    local devices_json tpv_json sky_json
    devices_json="$(echo "$raw" | grep '"class":"DEVICES"' | tail -n 1)"
    tpv_json="$(echo "$raw" | grep '"class":"TPV"' | tail -n 1)"
    sky_json="$(echo "$raw" | grep '"class":"SKY"' | tail -n 1)"

    local dev_count
    dev_count="$(echo "$devices_json" | jq -r '.devices // [] | length' 2>/dev/null)"
    dev_count="${dev_count:-0}"

    if [ "$dev_count" -eq 0 ] 2>/dev/null; then
        echo "gpsd: UP, no GPS device attached"
        return
    fi

    local mode
    mode="$(tpv_mode "$raw")"

    local fixword="NO FIX"
    [ "$mode" = "2" ] && fixword="2D"
    [ "$mode" = "3" ] && fixword="3D"

    local time_str time_disp="--"
    time_str="$(echo "$tpv_json" | jq -r '.time // empty' 2>/dev/null)"
    if [ -n "$time_str" ]; then
        local date_part clock_part
        date_part="${time_str%%T*}"
        clock_part="${time_str#*T}"
        clock_part="${clock_part%%.*}"
        time_disp="${date_part} ${clock_part} UTC"
    fi

    echo "[$time_disp] FIX: $fixword"

    if [ "$mode" -ge 2 ] 2>/dev/null; then
        local lat lon speed_ms track
        lat="$(echo "$tpv_json" | jq -r '.lat // empty' 2>/dev/null)"
        lon="$(echo "$tpv_json" | jq -r '.lon // empty' 2>/dev/null)"
        speed_ms="$(echo "$tpv_json" | jq -r '.speed // empty' 2>/dev/null)"
        track="$(echo "$tpv_json" | jq -r '.track // empty' 2>/dev/null)"

        if [ -n "$lat" ] && [ -n "$lon" ]; then
            echo "Lat/Lon: $lat, $lon"
        else
            echo "Lat/Lon: -- (no fix)"
        fi

        if [ -n "$speed_ms" ] && [ -n "$track" ]; then
            local speed_kmh point track_int
            speed_kmh="$(awk -v s="$speed_ms" 'BEGIN { printf "%.1f", s * 3.6 }')"
            point="$(compass_point "$track")"
            track_int="${track%.*}"
            echo "Speed: ${speed_kmh} km/h  Heading: ${track_int}° (${point})"
        else
            echo "Speed: -- Heading: --"
        fi
    else
        echo "Lat/Lon: -- (no fix)"
        echo "Speed: -- Heading: --"
    fi

    format_constellation "$sky_json"
}
```

- [ ] **Step 4: Run the test harness against the real functions**

Run:
```bash
source /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh 2>/dev/null
bash -c "source /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh; source /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard.sh"
```
(The first line is sourced inside the same `bash -c` as the test script so the functions are in scope when the checks run — `payload.sh` at this point has no top-level executable code yet, only function definitions, so sourcing it is side-effect-free.)

Expected: `PASS` for all checks, `ALL PASS`, exit 0. If anything fails, the diff printed by `check()` shows exactly which line of `format_block` output diverged — fix the function, not the fixture (the fixtures encode the spec's required behavior).

- [ ] **Step 5: Commit**

```bash
cd /Users/eighmy/repos/PineapplePager/payloads
git add library/user/general/gps-dashboard/payload.sh
git commit -m "$(cat <<'EOF'
Add gps-dashboard formatting layer

Pure functions that turn one raw gpspipe -w JSON sample into display
text and a LOG color: compass_point, tpv_mode, block_color,
format_constellation, format_block. No main loop yet - covered by
fixture tests, no device required.
EOF
)"
```

---

### Task 2: Sampling + main loop wiring

**Files:**
- Modify: `library/user/general/gps-dashboard/payload.sh` (append below the functions from Task 1)
- Test (scratch, not committed): `/private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard_loop.sh`

**Interfaces:**
- Consumes: `format_block RAW_JSON_TEXT`, `block_color RAW_JSON_TEXT` (from Task 1)
- Produces (consumed by Task 3's live verification): the complete, runnable `payload.sh` — a `main()` function containing the refresh loop (calls `LOG`, exits 0), invoked only under a sourced-vs-executed guard so the file can still be sourced for its function definitions without running the loop

**Design notes:**
- The loop calls a wrapper function `wait_for_exit` rather than inlining `timeout ... WAIT_FOR_BUTTON_PRESS ...` directly, purely so tests can override `wait_for_exit` with a plain shell function. `timeout` execs its argument as an external program via `PATH`, so it can never be pointed at a shell function — only the wrapper function *call itself* can be intercepted. This mirrors why the `gps-checker` work shimmed `LOG`/`WAIT_FOR_INPUT` as direct function calls rather than trying to override them at the `PATH` level.
- The loop itself lives in a `main` function, and the file's only top-level statement is a sourced-vs-executed guard (`if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main; fi`) that calls `main` only when the file is run directly, not when it's sourced. **This matters correctness-wise, not just for testing:** sourcing a file always (re)defines every function in it, including `wait_for_exit` — so if the loop were top-level code, a test that defines a `wait_for_exit` shim and *then* sources `payload.sh` would have its shim silently overwritten by the real one, which calls the real (locally nonexistent) `timeout`/`WAIT_FOR_BUTTON_PRESS` and fails instantly — turning `if wait_for_exit; then break; fi` into an unbounded tight loop instead of a graceful exit. This was caught by actually running this exact scenario while writing this plan: it spun for the full 2-minute tool timeout before being killed. Wrapping the loop in `main` and gating the call means tests can source the file (loading definitions only, no execution), install their shims *after* sourcing so they aren't clobbered, and then call `main` explicitly.

- [ ] **Step 1: Write the loop-wiring test harness**

Create `/private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard_loop.sh`:

```bash
#!/bin/bash
set -u

PAYLOAD="/Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh"
CAPTURE="/private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/gps_dashboard_log_capture.txt"
rm -f "$CAPTURE"

cat > /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/gps_dashboard_inner.sh <<INNER
LOG() { echo "LOG[\$1]: \$2" >> "$CAPTURE"; }
source "$PAYLOAD"
wait_for_exit() { return 0; }
main
INNER

bash /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/gps_dashboard_inner.sh
exit_code=$?

FAILS=0

if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: exit code was $exit_code, expected 0"
    FAILS=$((FAILS + 1))
else
    echo "PASS: exit code 0"
fi

if [ ! -f "$CAPTURE" ]; then
    echo "FAIL: LOG was never called"
    FAILS=$((FAILS + 1))
else
    lines="$(wc -l < "$CAPTURE" | tr -d ' ')"
    if [ "$lines" != "1" ]; then
        echo "FAIL: expected exactly 1 LOG call (wait_for_exit returns 0 on the first check), got $lines"
        FAILS=$((FAILS + 1))
    else
        echo "PASS: exactly one refresh cycle ran before exit"
    fi

    first_line="$(head -n 1 "$CAPTURE")"
    if [ "$first_line" = "LOG[red]: gpsd: DOWN" ]; then
        echo "PASS: single cycle logged the expected block (no gpsd/gpspipe on this dev machine, so raw is empty)"
    else
        echo "FAIL: unexpected LOG content: $first_line"
        FAILS=$((FAILS + 1))
    fi
fi

echo "----"
if [ "$FAILS" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILS FAILURE(S)"
    exit 1
fi
```

Note the order in the generated inner script: `source "$PAYLOAD"` happens *before* the `wait_for_exit` shim is defined, so the shim is the last (winning) definition of that name. `LOG` can be defined either before or after — `payload.sh` never defines a shell function called `LOG` (it only calls the real `LOG` binary), so there's nothing for the shim to collide with.

This test runs entirely on the dev machine, no SSH/device required: `gpspipe` may or may not be installed locally (it is on this machine, via Homebrew, but fails instantly with "connection refused" since no local gpsd is running) and GNU `timeout` is not installed locally, so `sample_gpsd` (once written in Step 3) produces an empty sample either way — exercising the "gpsd: DOWN" / red path already proven correct in Task 1. This test's job is to confirm the *loop wiring* (exactly one cycle runs, then `wait_for_exit` returning 0 ends the loop, then the script exits 0), not to re-prove formatting.

- [ ] **Step 2: Run the test to confirm it fails (loop code doesn't exist yet)**

Run:
```bash
bash /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard_loop.sh
```
Expected: an error sourcing `payload.sh` (`main`/`wait_for_exit` don't exist yet) and `FAIL: LOG was never called`.

- [ ] **Step 3: Append `sample_gpsd`, `wait_for_exit`, `main`, and the entry-point guard to `payload.sh`**

Add to the end of `library/user/general/gps-dashboard/payload.sh`:

```bash

# Pulls one JSON sample from gpsd. Bounded independently of the button-wait
# below so a slow/silent gpsd can't stall the refresh cadence.
sample_gpsd() {
    timeout "$SAMPLE_TIMEOUT_SECS" gpspipe -w -n "$SAMPLE_LINES" 2>/dev/null
}

# Blocks until the exit button is pressed or the refresh interval elapses.
# Returns 0 if B was pressed (caller should exit), 1 on timeout (caller
# should refresh and loop again). Its own function, not inlined, so tests
# can override it without needing the real WAIT_FOR_BUTTON_PRESS binary or
# a live Pager session.
wait_for_exit() {
    timeout "$REFRESH_INTERVAL_SECS" WAIT_FOR_BUTTON_PRESS B >/dev/null 2>&1
}

main() {
    while true; do
        raw="$(sample_gpsd)"
        LOG "$(block_color "$raw")" "$(format_block "$raw")"
        if wait_for_exit; then
            break
        fi
    done
    exit 0
}

# Only run main when this file is executed directly, not when it's sourced -
# lets tests source it for the function definitions without triggering the
# real loop (which would clobber any test shim of the same name - see the
# design note above).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main
fi
```

- [ ] **Step 4: Run the test again to confirm it passes**

Run:
```bash
bash /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard_loop.sh
```
Expected: `PASS` for all three checks, `ALL PASS`, exit 0.

- [ ] **Step 5: Re-run the Task 1 fixture tests to confirm nothing broke**

Because of the entry-point guard from Step 3, sourcing `payload.sh` now only loads definitions — it's safe to source directly, no extraction needed:

```bash
bash -c "source /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh; source /private/tmp/claude-504/-Users-eighmy-repos-PineapplePager/200189bf-c5b4-4189-87b9-d04cc4fb4906/scratchpad/test_gps_dashboard.sh"
```
Expected: `ALL PASS`, exit 0 — confirms Step 3's appended code didn't alter any function body from Task 1.

- [ ] **Step 6: Syntax check**

Run:
```bash
bash -n /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh
```
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
cd /Users/eighmy/repos/PineapplePager/payloads
git add library/user/general/gps-dashboard/payload.sh
git commit -m "$(cat <<'EOF'
Wire up gps-dashboard sampling loop

sample_gpsd pulls one bounded gpsd JSON sample per cycle; wait_for_exit
wraps the B-button timeout wait as its own function so it can be
overridden in tests without a live Pager session. The loop lives in
main(), called only when the file is executed directly (not sourced),
so sourcing for tests can't silently clobber a shimmed wait_for_exit
and spin forever - verified live while writing the plan for this.
Always exits 0 - the Pager flags any non-zero exit as a payload error.
EOF
)"
```

---

### Task 3: README, deploy, and live device verification

**Files:**
- Create: `library/user/general/gps-dashboard/README.md`
- Deploy target (not part of the git repo): `root@172.16.52.1:/root/payloads/user/general/gps-dashboard/`

**Interfaces:**
- Consumes: the finished `payload.sh` from Task 2
- Produces: nothing further consumes this — it's the last task

- [ ] **Step 1: Write the README**

Create `library/user/general/gps-dashboard/README.md`:

```markdown
# GPS Dashboard

**GPS Dashboard** is a live, auto-refreshing readout of everything gpsd
currently knows: connection/fix status, satellite constellation breakdown,
position, speed and heading, and UTC time.

- **Author:** KJ4M
- **Version:** 1.0

## Why?

[GPS Checker](../gps-checker) tells you *why* GPS isn't producing a fix.
Once it is working, GPS Dashboard gives you a live view of what it's
actually seeing - useful for confirming position while wardriving, watching
a fix improve as you get a clearer view of sky, or just checking what your
GPS currently reports without re-running a check by hand.

## Usage

Run the payload. It samples gpsd roughly every 2 seconds and logs one block
per sample:

```
[2026-08-11 02:38:33 UTC] FIX: 3D
Lat/Lon: 33.464887, -86.612453
Speed: 4.3 km/h  Heading: 184° (S)
Sats: GPS 5/8 used  GLONASS 2/3 used
```

Before a fix, it still shows connection and satellite state, with position,
speed, and heading blanked. If gpsd isn't reachable, or no GPS device is
attached, it says so instead of showing stale data.

Press **B** to exit.

This payload only displays GPS state - it doesn't restart gpsd or diagnose
problems. If GPS isn't working at all, run **GPS Checker** first.
```

- [ ] **Step 2: Deploy to the device**

Run:
```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 root@172.16.52.1 "mkdir -p /root/payloads/user/general/gps-dashboard"
scp -o BatchMode=yes -o ConnectTimeout=5 \
  /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/payload.sh \
  /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-dashboard/README.md \
  root@172.16.52.1:/root/payloads/user/general/gps-dashboard/
ssh -o BatchMode=yes -o ConnectTimeout=5 root@172.16.52.1 "chmod +x /root/payloads/user/general/gps-dashboard/payload.sh"
```
Expected: both files copy without error, `chmod` succeeds.

- [ ] **Step 3: Live single-cycle verification against real gpsd data**

Run:
```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 root@172.16.52.1 '
cat > /root/payloads/user/general/gps-dashboard/live_check_inner.sh <<INNER
LOG() { echo "LOG[\$1]: \$2"; }
source /root/payloads/user/general/gps-dashboard/payload.sh
wait_for_exit() { return 0; }
main
INNER
bash /root/payloads/user/general/gps-dashboard/live_check_inner.sh
echo "EXIT_CODE:$?"
rm -f /root/payloads/user/general/gps-dashboard/live_check_inner.sh
'
```
Expected: `EXIT_CODE:0`, and one `LOG[color]: ...` block whose content matches current real device state (e.g. `LOG[yellow]: [--] FIX: NO FIX ...` if indoors with no fix, or a `green` 3D block outdoors — either is a correct result; what matters is the block is well-formed and the color matches the fix state, not any specific fix state). If `gpsd` happens to be down at test time, expect `LOG[red]: gpsd: DOWN` instead — also correct, run `service gpsd restart` on the device and retry if you want to see the working-GPS path.

- [ ] **Step 4: Real hands-on-device pass**

From the Pager's physical menu (or Virtual Pager), launch **GPS Dashboard** and confirm by eye:
- The display refreshes automatically roughly every 2 seconds without any button press.
- Pressing **B** exits promptly and does *not* show an error banner (this was the exact bug fixed in `gps-checker` — confirm it doesn't recur here).
- Pressing other buttons (DPAD, A) while it's running does not exit or otherwise disrupt the loop.

- [ ] **Step 5: Commit**

```bash
cd /Users/eighmy/repos/PineapplePager/payloads
git add library/user/general/gps-dashboard/README.md
git commit -m "$(cat <<'EOF'
Add gps-dashboard README

Documents the live GPS readout payload, its relationship to
gps-checker, and the B-button exit.
EOF
)"
```

