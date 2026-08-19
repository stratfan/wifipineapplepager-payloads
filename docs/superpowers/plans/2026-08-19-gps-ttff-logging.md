# GPS TTFF Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Passively log time-to-first-fix (TTFF) after every gpsd (re)start in `gps-checker` and `wardrive_activate`, so the GPS hot-start improvement can be observed across real wardriving sessions instead of only manual A/B tests.

**Architecture:** Duplicate a small set of TTFF-poller functions into both payload files (matching this repo's existing no-shared-lib convention). Each payload spawns a detached background subshell right after gpsd starts; the subshell polls gpsd for a 3D fix (reusing the `gpspipe -w` + `mode:3` detection already proven on real hardware) and appends one result line to a shared log file. `gps-dashboard` is untouched — it never restarts gpsd itself, so it has nothing to measure TTFF from.

**Tech Stack:** POSIX/bash shell (payload.sh files run under `#!/bin/bash` on OpenWrt/BusyBox), `gpspipe`/gpsd JSON protocol, UCI (unrelated to this feature but present in the same files).

## Global Constraints

- Log file: `/root/wardrive_ttff.log`, plain text, appended to (never truncated) by both payloads.
- Success line format: `<UTC-ISO8601> <payload_name> injected=<yes|no> ttff=<N>s`, e.g. `2026-08-19T04:23:32Z wardrive_activate injected=yes ttff=165s`. Timestamp via `date -u +%Y-%m-%dT%H:%M:%SZ`, written when the fix lands or the timeout fires — not at poll start.
- Timeout line format: `<UTC-ISO8601> <payload_name> injected=<yes|no> ttff=timeout(600s)`.
- `payload_name` is a literal string per file: `gps-checker` or `wardrive_activate`.
- `injected` is derived from `inject_hotstart`'s own exit code (0 → `yes`, 1 → `no`).
- Poll loop: check every `TTFF_POLL_INTERVAL` (default 5) seconds, cap at `TTFF_POLL_TIMEOUT` (default 600) seconds.
- PID guard: before spawning, kill any still-alive PID recorded in `/tmp/ttff_poller.pid`, then overwrite it with the new poller's PID.
- No changes to `gps-dashboard/payload.sh`.
- No new shared library file — functions are duplicated verbatim (same names, same behavior) into both `gps-checker/payload.sh` and `wardrive_activate/payload.sh`, following the same convention the hot-start feature already established for `inject_hotstart`/`cache_fix`/etc.
- The fix-polling mechanism itself (`gpspipe -w` + `mode:3` detection) is already proven against real hardware — tests in this plan verify the new wiring (log formatting, PID guard, background spawn), not gpsd/gpspipe behavior itself.

---

### Task 1: TTFF poller in gps-checker

**Files:**
- Modify: `library/user/general/gps-checker/payload.sh` (insert new functions after `inject_hotstart()`'s closing brace, around line 201-204 — confirm exact position via `grep -n "restart_gpsd" library/user/general/gps-checker/payload.sh` before editing; also modify `restart_gpsd()` itself)
- Test: `/tmp/gps_ttff_tests/test_gps_checker.sh`

**Interfaces:**
- Produces (for Task 2 to duplicate verbatim, and for Task 3 to exercise on-device):
  - Globals: `TTFF_LOG_FILE` (default `/root/wardrive_ttff.log`), `TTFF_PID_FILE` (default `/tmp/ttff_poller.pid`), `TTFF_POLL_INTERVAL` (default `5`), `TTFF_POLL_TIMEOUT` (default `600`) — all overridable via pre-set environment variables (`"${VAR:-default}"`), which is how tests override them.
  - `_ttff_write_result_line(payload_name, injected, result)` — `result` is either a plain integer (elapsed seconds) or the literal string `timeout`. Appends one formatted line to `$TTFF_LOG_FILE`.
  - `_ttff_guard_poller(new_pid)` — kills any live PID currently in `$TTFF_PID_FILE`, then writes `new_pid` there.
  - `_ttff_poll_and_log(payload_name, injected)` — blocking; polls up to `$TTFF_POLL_TIMEOUT`, calls `_ttff_write_result_line` with the outcome. Never call this directly except backgrounded.
  - `start_ttff_poller(payload_name, injected)` — backgrounds `_ttff_poll_and_log`, then calls `_ttff_guard_poller` with its PID. This is the only entry point callers use.

- [ ] **Step 1: Confirm the exact insertion point**

Run: `grep -n "^inject_hotstart\|^restart_gpsd" library/user/general/gps-checker/payload.sh`
Expected: two lines, e.g. `135:inject_hotstart() {` and `204:restart_gpsd() {`. Note the line number of `restart_gpsd() {` — the new functions go immediately before the comment line directly above it (`# Restarts gpsd once, giving the device a moment to settle.`).

- [ ] **Step 2: Write the failing test**

Create `/tmp/gps_ttff_tests/test_gps_checker.sh`:

```bash
#!/bin/bash
set -u
mkdir -p /tmp/gps_ttff_tests

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        exit 1
    fi
}

# Deterministic timestamp for exact-line-content assertions below.
date() {
    if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
        echo "2026-08-19T04:23:32Z"
        return
    fi
    command date "$@"
}

# gps-checker/payload.sh has a BASH_SOURCE guard around its real
# run_check/while-loop (added during the hot-start feature), so sourcing
# it here only defines functions - no side effects, no fakes needed for
# LOG/service/uci/etc.
source /Users/eighmy/repos/PineapplePager/payloads/library/user/general/gps-checker/payload.sh

echo "== _ttff_write_result_line: success case =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/out_success.log
rm -f "$TTFF_LOG_FILE"
_ttff_write_result_line "gps-checker" "yes" "165"
assert_eq "success line content" \
    "2026-08-19T04:23:32Z gps-checker injected=yes ttff=165s" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== _ttff_write_result_line: timeout case =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/out_timeout.log
TTFF_POLL_TIMEOUT=600
rm -f "$TTFF_LOG_FILE"
_ttff_write_result_line "gps-checker" "no" "timeout"
assert_eq "timeout line content" \
    "2026-08-19T04:23:32Z gps-checker injected=no ttff=timeout(600s)" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== _ttff_write_result_line: appends, does not overwrite =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/out_append.log
rm -f "$TTFF_LOG_FILE"
_ttff_write_result_line "gps-checker" "yes" "10"
_ttff_write_result_line "gps-checker" "no" "20"
assert_eq "two appended lines" \
"2026-08-19T04:23:32Z gps-checker injected=yes ttff=10s
2026-08-19T04:23:32Z gps-checker injected=no ttff=20s" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== _ttff_guard_poller: dead PID is not killed, new PID recorded =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/dead.pid
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
echo "$dead_pid" > "$TTFF_PID_FILE"
_ttff_guard_poller 999
assert_eq "pid file updated after dead-pid guard" "999" "$(cat "$TTFF_PID_FILE")"

echo "== _ttff_guard_poller: live PID is killed, new PID recorded =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/live.pid
sleep 30 &
live_pid=$!
echo "$live_pid" > "$TTFF_PID_FILE"
_ttff_guard_poller 888
sleep 0.2
if kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: previous live poller was not killed"
    kill "$live_pid" 2>/dev/null
    exit 1
else
    echo "PASS: previous live poller was killed"
fi
assert_eq "pid file updated after live-pid guard" "888" "$(cat "$TTFF_PID_FILE")"

echo "== start_ttff_poller: spawns a background job, records its PID, logs on timeout =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/out_spawn.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/spawn.pid
TTFF_POLL_TIMEOUT=1
TTFF_POLL_INTERVAL=1
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
gpspipe() { :; }  # no fix ever arrives - forces the timeout path
start_ttff_poller "gps-checker" "no"
poller_pid="$(cat "$TTFF_PID_FILE")"
wait "$poller_pid" 2>/dev/null
assert_eq "spawned poller logged a timeout line" \
    "2026-08-19T04:23:32Z gps-checker injected=no ttff=timeout(1s)" \
    "$(cat "$TTFF_LOG_FILE")"

echo "ALL TESTS PASSED"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash /tmp/gps_ttff_tests/test_gps_checker.sh`
Expected: fails immediately — `payload.sh` doesn't yet define `_ttff_write_result_line` (or any of the other new functions).

- [ ] **Step 4: Insert the TTFF functions into gps-checker/payload.sh**

Immediately after `inject_hotstart()`'s closing `}` (and the blank line after it), before the `# Restarts gpsd once, giving the device a moment to settle.` comment, insert:

```bash
# --- GPS TTFF logging ----------------------------------------------------
# Passively records time-to-first-fix after a gpsd (re)start, so the
# hot-start improvement can be observed across real wardriving sessions
# instead of only manual A/B tests. See
# docs/superpowers/specs/2026-08-19-gps-ttff-logging-design.md.
TTFF_LOG_FILE="${TTFF_LOG_FILE:-/root/wardrive_ttff.log}"
TTFF_PID_FILE="${TTFF_PID_FILE:-/tmp/ttff_poller.pid}"
TTFF_POLL_INTERVAL="${TTFF_POLL_INTERVAL:-5}"
TTFF_POLL_TIMEOUT="${TTFF_POLL_TIMEOUT:-600}"

# Formats and appends one TTFF result line. $1=payload name literal,
# $2=injected (yes|no), $3=result - either the elapsed seconds as a plain
# integer, or the literal string "timeout".
_ttff_write_result_line() {
    local payload_name="$1" injected="$2" result="$3" ts ttff_field
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$result" = "timeout" ]; then
        ttff_field="timeout(${TTFF_POLL_TIMEOUT}s)"
    else
        ttff_field="${result}s"
    fi
    echo "${ts} ${payload_name} injected=${injected} ttff=${ttff_field}" >> "$TTFF_LOG_FILE" 2>/dev/null
}

# Kills any still-alive poller recorded in TTFF_PID_FILE, then records $1
# (the new poller's PID) there. Prevents overlapping pollers stacking up
# when gpsd is restarted more than once in a session.
_ttff_guard_poller() {
    local new_pid="$1" old_pid
    if [ -f "$TTFF_PID_FILE" ]; then
        old_pid="$(cat "$TTFF_PID_FILE" 2>/dev/null)"
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && kill "$old_pid" 2>/dev/null ;;
        esac
    fi
    echo "$new_pid" > "$TTFF_PID_FILE" 2>/dev/null
}

# Polls gpsd for a 3D fix and logs the result. $1=payload name literal,
# $2=injected (yes|no). Intended to run backgrounded via start_ttff_poller
# - never call directly in the foreground, it can block for up to
# TTFF_POLL_TIMEOUT seconds.
_ttff_poll_and_log() {
    local payload_name="$1" injected="$2" elapsed=0 line
    while [ "$elapsed" -lt "$TTFF_POLL_TIMEOUT" ]; do
        line=$(timeout 3 gpspipe -w -n 20 2>/dev/null | grep -m1 '"class":"TPV".*"mode":3')
        if [ -n "$line" ]; then
            _ttff_write_result_line "$payload_name" "$injected" "$elapsed"
            return
        fi
        sleep "$TTFF_POLL_INTERVAL"
        elapsed=$((elapsed + TTFF_POLL_INTERVAL))
    done
    _ttff_write_result_line "$payload_name" "$injected" "timeout"
}

# Spawns the background TTFF poller. $1=payload name literal (e.g.
# "gps-checker"), $2=injected (yes|no). Call immediately after gpsd has
# been (re)started - never blocks the caller.
start_ttff_poller() {
    local payload_name="$1" injected="$2"
    _ttff_poll_and_log "$payload_name" "$injected" &
    _ttff_guard_poller "$!"
}

```

- [ ] **Step 5: Run test to verify the new functions pass in isolation**

Run: `bash /tmp/gps_ttff_tests/test_gps_checker.sh`
Expected: all lines up through the `start_ttff_poller` block print `PASS:`, final line `ALL TESTS PASSED`, exit `0`.

- [ ] **Step 6: Wire `start_ttff_poller` into `restart_gpsd()`**

Replace the existing `restart_gpsd()`:

```bash
# Restarts gpsd once, giving the device a moment to settle.
restart_gpsd() {
    LOG yellow "Restarting gpsd..."
    local device
    if device="$(resolve_gps_device)"; then
        trap 'service gpsd start' EXIT INT TERM
        service gpsd stop
        inject_hotstart "$device"
        sleep 0.5
        service gpsd start
        trap - EXIT INT TERM
    else
        service gpsd restart
    fi
    sleep 2
}
```

with:

```bash
# Restarts gpsd once, giving the device a moment to settle.
restart_gpsd() {
    LOG yellow "Restarting gpsd..."
    local device injected=no
    if device="$(resolve_gps_device)"; then
        trap 'service gpsd start' EXIT INT TERM
        service gpsd stop
        if inject_hotstart "$device"; then injected=yes; fi
        sleep 0.5
        service gpsd start
        trap - EXIT INT TERM
        start_ttff_poller "gps-checker" "$injected"
    else
        service gpsd restart
    fi
    sleep 2
}
```

(The `else` branch, where `resolve_gps_device` itself fails, has no known device and never called `inject_hotstart`, so there's no meaningful `injected` value to log — no poller is started there.)

- [ ] **Step 7: Re-run the full test file**

Run: `bash /tmp/gps_ttff_tests/test_gps_checker.sh`
Expected: unchanged from Step 5 — `restart_gpsd()`'s body isn't exercised by this test file, so this step only confirms the edit didn't break sourcing. All `PASS:`, `ALL TESTS PASSED`, exit `0`.

- [ ] **Step 8: Syntax check the whole file**

Run: `bash -n library/user/general/gps-checker/payload.sh`
Expected: no output, exit code `0`.

- [ ] **Step 9: Commit**

```bash
git add library/user/general/gps-checker/payload.sh
git commit -m "feat(gps-checker): log time-to-first-fix after gpsd restart"
```

---

### Task 2: TTFF poller in wardrive_activate

**Files:**
- Modify: `library/user/general/wardrive_activate/payload.sh` (insert new functions immediately after `inject_hotstart()`'s closing brace at line 152, before the `# ===== INTERNALS` divider comment at line 154; also modify the gpsd-restart block around line 316-334)
- Test: `/tmp/gps_ttff_tests/test_wardrive_activate.sh`

**Interfaces:**
- Consumes: nothing from Task 1 — `wardrive_activate/payload.sh` is a separate file and gets its own verbatim copy of the same four functions (`_ttff_write_result_line`, `_ttff_guard_poller`, `_ttff_poll_and_log`, `start_ttff_poller`) with identical names, signatures, and behavior to Task 1's. Do not rename or reshape them — the log format and globals must match exactly so both payloads write compatible lines to the same shared file.
- Produces: nothing new for later tasks; Task 3 exercises both payloads' `start_ttff_poller` on real hardware.

- [ ] **Step 1: Confirm the exact insertion points**

Run: `grep -n "^inject_hotstart\|^# ====\|^LOG \"Restarting gpsd\|^LOG \"Detecting GPS devices" library/user/general/wardrive_activate/payload.sh`
Expected: confirms `inject_hotstart() {` at line 86, its closing brace shortly before the `# =====...` INTERNALS divider (line 154 as of this plan being written), `LOG "Restarting gpsd..."` around line 324, and `LOG "Detecting GPS devices..."` around line 240 (this last one is the sourcing boundary the test uses in Step 2 — confirm it's still the first top-level executable statement).

- [ ] **Step 2: Write the failing test**

Create `/tmp/gps_ttff_tests/test_wardrive_activate.sh`:

```bash
#!/bin/bash
set -u
mkdir -p /tmp/gps_ttff_tests

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        exit 1
    fi
}

date() {
    if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
        echo "2026-08-19T04:23:32Z"
        return
    fi
    command date "$@"
}

# wardrive_activate's main flow runs unconditionally (no BASH_SOURCE guard
# - see docs/superpowers/plans/2026-08-15-gps-hotstart.md Task covering
# wardrive_activate's tests for why). Extract and source only the function
# definitions block, up to (not including) the first top-level statement.
sed -n '1,/^LOG "Detecting GPS devices/p' \
    /Users/eighmy/repos/PineapplePager/payloads/library/user/general/wardrive_activate/payload.sh \
    | sed '$d' > /tmp/gps_ttff_tests/_wardrive_functions_only.sh
source /tmp/gps_ttff_tests/_wardrive_functions_only.sh

echo "== _ttff_write_result_line: success case =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_out_success.log
rm -f "$TTFF_LOG_FILE"
_ttff_write_result_line "wardrive_activate" "yes" "165"
assert_eq "success line content" \
    "2026-08-19T04:23:32Z wardrive_activate injected=yes ttff=165s" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== _ttff_write_result_line: timeout case =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_out_timeout.log
TTFF_POLL_TIMEOUT=600
rm -f "$TTFF_LOG_FILE"
_ttff_write_result_line "wardrive_activate" "no" "timeout"
assert_eq "timeout line content" \
    "2026-08-19T04:23:32Z wardrive_activate injected=no ttff=timeout(600s)" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== _ttff_guard_poller: dead PID is not killed, new PID recorded =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_dead.pid
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
echo "$dead_pid" > "$TTFF_PID_FILE"
_ttff_guard_poller 999
assert_eq "pid file updated after dead-pid guard" "999" "$(cat "$TTFF_PID_FILE")"

echo "== _ttff_guard_poller: live PID is killed, new PID recorded =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_live.pid
sleep 30 &
live_pid=$!
echo "$live_pid" > "$TTFF_PID_FILE"
_ttff_guard_poller 888
sleep 0.2
if kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: previous live poller was not killed"
    kill "$live_pid" 2>/dev/null
    exit 1
else
    echo "PASS: previous live poller was killed"
fi
assert_eq "pid file updated after live-pid guard" "888" "$(cat "$TTFF_PID_FILE")"

echo "== start_ttff_poller: spawns a background job, records its PID, logs on timeout =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_out_spawn.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_spawn.pid
TTFF_POLL_TIMEOUT=1
TTFF_POLL_INTERVAL=1
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
gpspipe() { :; }
start_ttff_poller "wardrive_activate" "no"
poller_pid="$(cat "$TTFF_PID_FILE")"
wait "$poller_pid" 2>/dev/null
assert_eq "spawned poller logged a timeout line" \
    "2026-08-19T04:23:32Z wardrive_activate injected=no ttff=timeout(1s)" \
    "$(cat "$TTFF_LOG_FILE")"

echo "ALL TESTS PASSED"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash /tmp/gps_ttff_tests/test_wardrive_activate.sh`
Expected: fails — `_ttff_write_result_line` isn't defined yet in `wardrive_activate/payload.sh`.

- [ ] **Step 4: Insert the same TTFF functions into wardrive_activate/payload.sh**

Immediately after `inject_hotstart()`'s closing `}` (the block ending `kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null\n    return 1\n}`), before the `# =============================================================================\n# INTERNALS: helpers and device detection\n# =============================================================================` divider, insert this block — identical to Task 1's, same four functions, same globals, same comments, same behavior:

```bash
# --- GPS TTFF logging ----------------------------------------------------
# Passively records time-to-first-fix after a gpsd (re)start, so the
# hot-start improvement can be observed across real wardriving sessions
# instead of only manual A/B tests. See
# docs/superpowers/specs/2026-08-19-gps-ttff-logging-design.md.
TTFF_LOG_FILE="${TTFF_LOG_FILE:-/root/wardrive_ttff.log}"
TTFF_PID_FILE="${TTFF_PID_FILE:-/tmp/ttff_poller.pid}"
TTFF_POLL_INTERVAL="${TTFF_POLL_INTERVAL:-5}"
TTFF_POLL_TIMEOUT="${TTFF_POLL_TIMEOUT:-600}"

# Formats and appends one TTFF result line. $1=payload name literal,
# $2=injected (yes|no), $3=result - either the elapsed seconds as a plain
# integer, or the literal string "timeout".
_ttff_write_result_line() {
    local payload_name="$1" injected="$2" result="$3" ts ttff_field
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$result" = "timeout" ]; then
        ttff_field="timeout(${TTFF_POLL_TIMEOUT}s)"
    else
        ttff_field="${result}s"
    fi
    echo "${ts} ${payload_name} injected=${injected} ttff=${ttff_field}" >> "$TTFF_LOG_FILE" 2>/dev/null
}

# Kills any still-alive poller recorded in TTFF_PID_FILE, then records $1
# (the new poller's PID) there. Prevents overlapping pollers stacking up
# when gpsd is restarted more than once in a session.
_ttff_guard_poller() {
    local new_pid="$1" old_pid
    if [ -f "$TTFF_PID_FILE" ]; then
        old_pid="$(cat "$TTFF_PID_FILE" 2>/dev/null)"
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && kill "$old_pid" 2>/dev/null ;;
        esac
    fi
    echo "$new_pid" > "$TTFF_PID_FILE" 2>/dev/null
}

# Polls gpsd for a 3D fix and logs the result. $1=payload name literal,
# $2=injected (yes|no). Intended to run backgrounded via start_ttff_poller
# - never call directly in the foreground, it can block for up to
# TTFF_POLL_TIMEOUT seconds.
_ttff_poll_and_log() {
    local payload_name="$1" injected="$2" elapsed=0 line
    while [ "$elapsed" -lt "$TTFF_POLL_TIMEOUT" ]; do
        line=$(timeout 3 gpspipe -w -n 20 2>/dev/null | grep -m1 '"class":"TPV".*"mode":3')
        if [ -n "$line" ]; then
            _ttff_write_result_line "$payload_name" "$injected" "$elapsed"
            return
        fi
        sleep "$TTFF_POLL_INTERVAL"
        elapsed=$((elapsed + TTFF_POLL_INTERVAL))
    done
    _ttff_write_result_line "$payload_name" "$injected" "timeout"
}

# Spawns the background TTFF poller. $1=payload name literal (e.g.
# "gps-checker"), $2=injected (yes|no). Call immediately after gpsd has
# been (re)started - never blocks the caller.
start_ttff_poller() {
    local payload_name="$1" injected="$2"
    _ttff_poll_and_log "$payload_name" "$injected" &
    _ttff_guard_poller "$!"
}

```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash /tmp/gps_ttff_tests/test_wardrive_activate.sh`
Expected: all `PASS:`, final line `ALL TESTS PASSED`, exit `0`.

- [ ] **Step 6: Wire `start_ttff_poller` into the gpsd-restart block**

Replace:

```bash
LOG "Restarting gpsd..."
# Restart gpsd to apply the new GPS device configuration, priming the
# receiver with the last known fix first when one is cached (see
# inject_hotstart above) for a faster time-to-first-fix. selected_device
# is already a validated character device by this point (checked above).
trap '/etc/init.d/gpsd start' EXIT INT TERM
/etc/init.d/gpsd stop
inject_hotstart "$selected_device"
sleep 0.5
/etc/init.d/gpsd start
trap - EXIT INT TERM
```

with:

```bash
LOG "Restarting gpsd..."
# Restart gpsd to apply the new GPS device configuration, priming the
# receiver with the last known fix first when one is cached (see
# inject_hotstart above) for a faster time-to-first-fix. selected_device
# is already a validated character device by this point (checked above).
trap '/etc/init.d/gpsd start' EXIT INT TERM
/etc/init.d/gpsd stop
injected=no
if inject_hotstart "$selected_device"; then injected=yes; fi
sleep 0.5
/etc/init.d/gpsd start
trap - EXIT INT TERM
start_ttff_poller "wardrive_activate" "$injected"
```

(`injected` is a plain top-level variable here, not `local` — this matches the rest of `wardrive_activate/payload.sh`'s existing top-level scripting style, e.g. `selected_device`, `wigle_file`.)

- [ ] **Step 7: Re-run the full test file**

Run: `bash /tmp/gps_ttff_tests/test_wardrive_activate.sh`
Expected: unchanged from Step 5 — the sourcing boundary in this test stops before this block executes. All `PASS:`, `ALL TESTS PASSED`, exit `0`.

- [ ] **Step 8: Syntax check the whole file**

Run: `bash -n library/user/general/wardrive_activate/payload.sh`
Expected: no output, exit code `0`.

- [ ] **Step 9: Commit**

```bash
git add library/user/general/wardrive_activate/payload.sh
git commit -m "feat(wardrive_activate): log time-to-first-fix after gpsd restart"
```

---

### Task 3: On-device verification

**Files:**
- None modified — this task deploys and exercises Task 1 and Task 2's changes on the real Pager hardware at `root@172.16.52.1`.

**Interfaces:**
- Consumes: `start_ttff_poller`, `restart_gpsd` (gps-checker), and the gpsd-restart block (wardrive_activate) from Tasks 1-2, deployed as-is.

- [ ] **Step 1: Deploy both updated files**

Run:
```bash
scp -o ConnectTimeout=8 library/user/general/gps-checker/payload.sh root@172.16.52.1:/root/payloads/user/general/gps-checker/payload.sh
scp -o ConnectTimeout=8 library/user/general/wardrive_activate/payload.sh root@172.16.52.1:/root/payloads/user/general/wardrive_activate/payload.sh
```
Expected: both `scp` calls complete without error.

- [ ] **Step 2: Syntax check on-device**

Run:
```bash
ssh -o ConnectTimeout=8 root@172.16.52.1 'bash -n /root/payloads/user/general/gps-checker/payload.sh && bash -n /root/payloads/user/general/wardrive_activate/payload.sh && echo SYNTAX_OK'
```
Expected: prints `SYNTAX_OK`.

- [ ] **Step 3: Exercise gps-checker's `restart_gpsd` on-device and confirm the poller spawns**

Run (single SSH command):
```bash
ssh -o ConnectTimeout=8 root@172.16.52.1 '
rm -f /tmp/ttff_poller.pid /root/wardrive_ttff.log
PAYLOAD_GET_CONFIG() { uci -q get "payload.$1.$2" 2>/dev/null; }
PAYLOAD_SET_CONFIG() { uci -q set "payload.$1.$2=$3" && uci commit payload; }
LOG() { :; }
source /root/payloads/user/general/gps-checker/payload.sh
restart_gpsd
sleep 1
pid="$(cat /tmp/ttff_poller.pid 2>/dev/null)"
echo "poller_pid=$pid"
kill -0 "$pid" 2>/dev/null && echo "POLLER_ALIVE" || echo "POLLER_NOT_ALIVE"
'
```
Expected: `poller_pid=<some number>` followed by `POLLER_ALIVE` — confirms `restart_gpsd` on real hardware spawns the background poller and records a live PID (the guard's BASH_SOURCE-safe sourcing means this doesn't trigger the interactive `run_check`/button-wait loop).

- [ ] **Step 4: Wait for a real result line, or confirm the poller is still working**

Run:
```bash
ssh -o ConnectTimeout=8 root@172.16.52.1 '
for i in $(seq 1 12); do
    if [ -s /root/wardrive_ttff.log ]; then
        echo "LOG_LINE:"
        cat /root/wardrive_ttff.log
        exit 0
    fi
    sleep 5
done
echo "NO_LINE_YET_AFTER_60S"
pid="$(cat /tmp/ttff_poller.pid 2>/dev/null)"
kill -0 "$pid" 2>/dev/null && echo "POLLER_STILL_ALIVE" || echo "POLLER_DIED_WITHOUT_LOGGING"
'
```
Expected: either `LOG_LINE:` followed by a line matching `<timestamp> gps-checker injected=<yes|no> ttff=<N>s` (a real fix landed within 60s — plausible if the receiver already had recent aiding data), or `NO_LINE_YET_AFTER_60S` followed by `POLLER_STILL_ALIVE` (no fix yet, but the poller hasn't crashed — acceptable, since a genuine TTFF can take several minutes and this step isn't meant to wait that long). `POLLER_DIED_WITHOUT_LOGGING` is the only failing outcome — it means the poller exited without writing a result line, a real bug to investigate.

- [ ] **Step 5: Repeat Steps 3-4 for wardrive_activate**

Run (single SSH command):
```bash
ssh -o ConnectTimeout=8 root@172.16.52.1 '
rm -f /tmp/ttff_poller.pid /root/wardrive_ttff.log
sed -n "1,/^LOG \"Detecting GPS devices/p" /root/payloads/user/general/wardrive_activate/payload.sh | sed "\$d" > /tmp/_wa_funcs.sh
PAYLOAD_GET_CONFIG() { uci -q get "payload.$1.$2" 2>/dev/null; }
LOG() { :; }
source /tmp/_wa_funcs.sh
device="$(readlink -f /dev/serial/by-path/*)"
device="$(echo "$device" | head -n1)"
LOG "Restarting gpsd..."
trap "/etc/init.d/gpsd start" EXIT INT TERM
/etc/init.d/gpsd stop
injected=no
if inject_hotstart "$device"; then injected=yes; fi
sleep 0.5
/etc/init.d/gpsd start
trap - EXIT INT TERM
start_ttff_poller "wardrive_activate" "$injected"
sleep 1
pid="$(cat /tmp/ttff_poller.pid 2>/dev/null)"
echo "poller_pid=$pid injected=$injected"
kill -0 "$pid" 2>/dev/null && echo "POLLER_ALIVE" || echo "POLLER_NOT_ALIVE"
'
```
Expected: `poller_pid=<number> injected=<yes|no>` then `POLLER_ALIVE`. (This step re-creates the same restart sequence `wardrive_activate`'s own top-level flow performs, since sourcing only the function-definitions block means the real top-level flow — including `GPS_CONFIGURE` and `WIGLE_START`, which are DuckyScript builtins unavailable outside the payload runner — can't run directly over SSH; see the existing "DuckyScript commands ... don't work outside the real payload runner" limitation noted in this project's testing history.)

Then poll for a result line the same way as Step 4:
```bash
ssh -o ConnectTimeout=8 root@172.16.52.1 '
for i in $(seq 1 12); do
    if [ -s /root/wardrive_ttff.log ]; then
        echo "LOG_LINE:"
        cat /root/wardrive_ttff.log
        exit 0
    fi
    sleep 5
done
echo "NO_LINE_YET_AFTER_60S"
pid="$(cat /tmp/ttff_poller.pid 2>/dev/null)"
kill -0 "$pid" 2>/dev/null && echo "POLLER_STILL_ALIVE" || echo "POLLER_DIED_WITHOUT_LOGGING"
'
```
Expected: same acceptance criteria as Step 4.

- [ ] **Step 6: Report results**

No commit in this task (nothing in the repo changed). Summarize what was observed in Steps 3-5 (PIDs spawned, whether real result lines appeared, their content) for the human partner.
