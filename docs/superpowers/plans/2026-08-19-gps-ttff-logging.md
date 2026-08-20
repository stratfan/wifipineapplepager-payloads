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
  - `_ttff_kill_previous_poller()` — kills any live PID currently in `$TTFF_PID_FILE`, if any. Takes no arguments; call BEFORE spawning a new poller.
  - `_ttff_record_poller_pid(pid)` — writes `pid` to `$TTFF_PID_FILE`. Call AFTER spawning, once the new poller's real PID (`$!`) is known.
  - `_ttff_poll_and_log(payload_name, injected)` — blocking; polls up to `$TTFF_POLL_TIMEOUT`, calls `_ttff_write_result_line` with the outcome. Never call this directly except backgrounded.
  - `start_ttff_poller(payload_name, injected)` — kills any previous poller first, backgrounds `_ttff_poll_and_log`, then records its PID. This is the only entry point callers use.

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

# Deterministic timestamp for exact-line-content assertions below. Only
# the `-u +%Y-%m-%dT%H:%M:%SZ` form (used by _ttff_write_result_line's
# timestamp) is faked; `date +%s` (used by _ttff_poll_and_log's
# wall-clock elapsed accounting) intentionally falls through to the real
# clock below, since that accounting needs genuine elapsed time to be
# meaningfully tested - see the "elapsed reflects real wall-clock time"
# case further down, which measures against real time rather than
# asserting an exact faked value.
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
#
# Points at the gps-ttff-logging worktree, not the main checkout - the
# main checkout's master branch has no committed TTFF code of its own, so
# sourcing it there would silently test stale or absent functions.
source /Users/eighmy/repos/PineapplePager/payloads/.worktrees/gps-ttff-logging/library/user/general/gps-checker/payload.sh

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

echo "== _ttff_kill_previous_poller: dead PID is left alone, no error =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/dead.pid
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
echo "$dead_pid" > "$TTFF_PID_FILE"
_ttff_kill_previous_poller
echo "PASS: _ttff_kill_previous_poller completed without error on a dead PID"

echo "== _ttff_kill_previous_poller: live PID is killed =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/live.pid
sleep 30 &
live_pid=$!
echo "$live_pid" > "$TTFF_PID_FILE"
_ttff_kill_previous_poller
sleep 0.2
if kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: previous live poller was not killed"
    kill "$live_pid" 2>/dev/null
    exit 1
else
    echo "PASS: previous live poller was killed"
fi

echo "== _ttff_record_poller_pid: writes the given PID to TTFF_PID_FILE =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/record.pid
rm -f "$TTFF_PID_FILE"
_ttff_record_poller_pid 777
assert_eq "pid file contains the recorded pid" "777" "$(cat "$TTFF_PID_FILE")"

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

echo "== start_ttff_poller: kills a still-live previous poller BEFORE recording the new PID =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/out_order.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/order.pid
TTFF_POLL_TIMEOUT=1
TTFF_POLL_INTERVAL=1
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
sleep 30 &
old_live_pid=$!
echo "$old_live_pid" > "$TTFF_PID_FILE"
gpspipe() { :; }
start_ttff_poller "gps-checker" "no"
new_pid="$(cat "$TTFF_PID_FILE")"
if [ "$new_pid" = "$old_live_pid" ]; then
    echo "FAIL: pid file still holds the old poller's pid"
    kill "$old_live_pid" 2>/dev/null
    exit 1
fi
if kill -0 "$old_live_pid" 2>/dev/null; then
    echo "FAIL: old poller was not killed by start_ttff_poller"
    kill "$old_live_pid" "$new_pid" 2>/dev/null
    exit 1
else
    echo "PASS: old poller was killed and pid file now holds the new poller's pid"
fi
wait "$new_pid" 2>/dev/null
assert_eq "new poller logged a timeout line" \
    "2026-08-19T04:23:32Z gps-checker injected=no ttff=timeout(1s)" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== start_ttff_poller: does not hold the caller's stdout/stderr open =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/fdtest.pid
TTFF_LOG_FILE=/tmp/gps_ttff_tests/fdtest.log
TTFF_POLL_TIMEOUT=30
TTFF_POLL_INTERVAL=5
rm -f "$TTFF_PID_FILE" "$TTFF_LOG_FILE"
gpspipe() { :; }  # never returns a fix - poller stays alive the full 30s if not fixed
fifo=/tmp/gps_ttff_tests/fdtest.fifo
readerdone=/tmp/gps_ttff_tests/fdtest.reader_done
readerrc=/tmp/gps_ttff_tests/fdtest.reader_rc
rm -f "$fifo" "$readerdone" "$readerrc"
mkfifo "$fifo"
# Open the read end in the background FIRST: opening a FIFO for write blocks
# until a reader is present, so the reader must already be waiting before
# start_ttff_poller's redirect opens the write end below.
( timeout 5 cat "$fifo" >/dev/null; echo $? > "$readerrc"; touch "$readerdone" ) &
reader_pid=$!
sleep 0.3
( start_ttff_poller "gps-checker" "no" >"$fifo" 2>&1 )
# start_ttff_poller itself returns immediately either way (it backgrounds the poller).
# The bug is that the backgrounded child keeps a dup of the fifo's write end open,
# so the fifo never sees a final close and the reader never gets EOF. Poll (bounded)
# for the reader to finish; if it doesn't finish promptly with rc=0 (clean EOF before
# its own timeout), the poller is still holding the write end open.
waited=0
while [ ! -f "$readerdone" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ -f "$readerdone" ] && [ "$(cat "$readerrc" 2>/dev/null)" = "0" ]; then
    echo "PASS: fifo reached EOF promptly, poller does not hold stdout/stderr open"
else
    echo "FAIL: reading from fifo timed out - poller is still holding stdout/stderr open"
    kill "$(cat "$TTFF_PID_FILE" 2>/dev/null)" 2>/dev/null
    kill "$reader_pid" 2>/dev/null
    rm -f "$fifo" "$readerdone" "$readerrc"
    exit 1
fi
kill "$(cat "$TTFF_PID_FILE" 2>/dev/null)" 2>/dev/null
kill "$reader_pid" 2>/dev/null
rm -f "$fifo" "$readerdone" "$readerrc"

echo "== _ttff_poll_and_log: elapsed reflects real wall-clock time, not just sleep durations =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wallclock.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/wallclock.pid
TTFF_POLL_TIMEOUT=30
TTFF_POLL_INTERVAL=10
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
# Simulates gpspipe blocking for ~2 real seconds before returning a hit on
# the very FIRST iteration - the loop's `sleep "$TTFF_POLL_INTERVAL"` never
# runs, so a sleep-only elapsed accumulator would log ttff=0s even though
# ~2 real seconds actually passed. This is exactly the undercounting bug
# the wall-clock (`date +%s`) accounting fixes.
gpspipe() { sleep 2; echo '{"class":"TPV","mode":3}'; }
# The real `timeout` binary execve()s its target directly, so it can
# never see gpspipe when gpspipe is a shell function (same limitation
# documented for ubx_write_frame in payload.sh) - swap in a plain
# passthrough here so this call actually reaches the stubbed gpspipe.
# gpspipe's own `sleep 2` already bounds this to ~2s, so no hard timeout
# of its own is needed.
timeout() { shift; "$@"; }
before="$(command date +%s)"
_ttff_poll_and_log "gps-checker" "no"
after="$(command date +%s)"
unset -f timeout
real_elapsed=$((after - before))
logged_ttff="$(grep -o 'ttff=[0-9]*s' "$TTFF_LOG_FILE" 2>/dev/null | grep -o '[0-9]*')"
if [ -z "$logged_ttff" ]; then
    echo "FAIL: no numeric ttff value logged (got: $(cat "$TTFF_LOG_FILE" 2>/dev/null))"
    exit 1
elif [ "$logged_ttff" -lt 1 ]; then
    echo "FAIL: logged ttff=${logged_ttff}s undercounts - gpspipe alone took ~2 real seconds"
    exit 1
elif [ $(( real_elapsed - logged_ttff )) -gt 2 ] 2>/dev/null || [ $(( real_elapsed - logged_ttff )) -lt -2 ] 2>/dev/null; then
    echo "FAIL: logged ttff=${logged_ttff}s is not close to the real measured ${real_elapsed}s"
    exit 1
else
    echo "PASS: logged ttff=${logged_ttff}s reflects real wall-clock time (measured ${real_elapsed}s)"
fi

echo "== _ttff_poll_and_log: clears TTFF_PID_FILE on exit if it still names this process =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/pidclear.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/pidclear.pid
TTFF_POLL_TIMEOUT=1
TTFF_POLL_INTERVAL=1
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
gpspipe() { :; }  # no fix ever arrives - forces the timeout path
echo "$$" > "$TTFF_PID_FILE"   # simulate this process having recorded its own pid
_ttff_poll_and_log "gps-checker" "no"
if [ -f "$TTFF_PID_FILE" ]; then
    echo "FAIL: TTFF_PID_FILE still exists after _ttff_poll_and_log exited (stale PID left behind)"
    exit 1
else
    echo "PASS: TTFF_PID_FILE was cleared on exit"
fi

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
# integer, or the literal string "timeout". Grouped so 2>/dev/null covers
# a failed *open* of TTFF_LOG_FILE too, not just a post-open write error -
# redirects apply left-to-right, so `cmd >>file 2>/dev/null` alone would
# leak an open failure to the original stderr before the suppression took
# effect.
_ttff_write_result_line() {
    local payload_name="$1" injected="$2" result="$3" ts ttff_field
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$result" = "timeout" ]; then
        ttff_field="timeout(${TTFF_POLL_TIMEOUT}s)"
    else
        ttff_field="${result}s"
    fi
    { echo "${ts} ${payload_name} injected=${injected} ttff=${ttff_field}" >> "$TTFF_LOG_FILE"; } 2>/dev/null
}

# Kills any still-alive poller recorded in TTFF_PID_FILE. Call BEFORE
# spawning a new poller, so a stale poller is never left running
# concurrently with a fresh one.
_ttff_kill_previous_poller() {
    local old_pid
    if [ -f "$TTFF_PID_FILE" ]; then
        old_pid="$(cat "$TTFF_PID_FILE" 2>/dev/null)"
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && kill "$old_pid" 2>/dev/null ;;
        esac
    fi
}

# Records $1 (a poller's PID) in TTFF_PID_FILE. Call AFTER spawning the
# poller, once its real PID ($!) is known. Grouped so 2>/dev/null covers a
# failed *open* of TTFF_PID_FILE too - unlike _ttff_write_result_line,
# this runs in the caller's foreground context, so an unsuppressed open
# failure would leak a raw shell error into the payload's interactive
# output instead of failing silently.
_ttff_record_poller_pid() {
    { echo "$1" > "$TTFF_PID_FILE"; } 2>/dev/null
}

# Clears TTFF_PID_FILE if it still names this process. Call on every exit
# path of _ttff_poll_and_log so a finished poller never leaves a stale PID
# behind - an uncleared stale PID risks the OS eventually reusing it for
# an unrelated process, which _ttff_kill_previous_poller would then kill.
_ttff_clear_own_pid() {
    [ "$(cat "$TTFF_PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$TTFF_PID_FILE"
}

# Polls gpsd for a 3D fix and logs the result. $1=payload name literal,
# $2=injected (yes|no). Intended to run backgrounded via start_ttff_poller
# - never call directly in the foreground, it can block for up to
# TTFF_POLL_TIMEOUT seconds. Elapsed time is real wall-clock time (via
# `date +%s`), not a sum of sleep durations - each iteration's
# `timeout 3 gpspipe ...` can itself take up to 3 real seconds, and that
# time must count too or the logged ttff value (and the loop's own
# TTFF_POLL_TIMEOUT cap) would systematically undercount real elapsed
# time, defeating the point of comparing these numbers against wall-clock
# hardware baselines.
_ttff_poll_and_log() {
    local payload_name="$1" injected="$2" start elapsed line
    start="$(date +%s)"
    elapsed=0
    while [ "$elapsed" -lt "$TTFF_POLL_TIMEOUT" ]; do
        line=$(timeout 3 gpspipe -w -n 20 2>/dev/null | grep -m1 '"class":"TPV".*"mode":3')
        if [ -n "$line" ]; then
            elapsed=$(( $(date +%s) - start ))
            _ttff_write_result_line "$payload_name" "$injected" "$elapsed"
            _ttff_clear_own_pid
            return
        fi
        sleep "$TTFF_POLL_INTERVAL"
        elapsed=$(( $(date +%s) - start ))
    done
    _ttff_write_result_line "$payload_name" "$injected" "timeout"
    _ttff_clear_own_pid
}

# Spawns the background TTFF poller. $1=payload name literal (e.g.
# "gps-checker"), $2=injected (yes|no). Call immediately after gpsd has
# been (re)started - never blocks the caller. Kills any still-running
# previous poller first, so pollers never overlap. Redirects the poller's
# stdio away from the caller's - without this, a non-interactive caller
# (e.g. a plain SSH command) whose stdout/stderr the poller inherited
# would hang waiting for those streams to close, even though the caller
# itself returns immediately.
start_ttff_poller() {
    local payload_name="$1" injected="$2"
    _ttff_kill_previous_poller
    _ttff_poll_and_log "$payload_name" "$injected" </dev/null >/dev/null 2>&1 &
    _ttff_record_poller_pid "$!"
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
- Consumes: nothing from Task 1 — `wardrive_activate/payload.sh` is a separate file and gets its own verbatim copy of the same five functions (`_ttff_write_result_line`, `_ttff_kill_previous_poller`, `_ttff_record_poller_pid`, `_ttff_poll_and_log`, `start_ttff_poller`) with identical names, signatures, and behavior to Task 1's. Do not rename or reshape them — the log format and globals must match exactly so both payloads write compatible lines to the same shared file.
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

# Only the `-u +%Y-%m-%dT%H:%M:%SZ` form (used by _ttff_write_result_line's
# timestamp) is faked; `date +%s` (used by _ttff_poll_and_log's
# wall-clock elapsed accounting) intentionally falls through to the real
# clock below, since that accounting needs genuine elapsed time to be
# meaningfully tested - see the "elapsed reflects real wall-clock time"
# case further down, which measures against real time rather than
# asserting an exact faked value.
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
#
# Points at the gps-ttff-logging worktree, not the main checkout - the
# main checkout's master branch has no committed TTFF code of its own, so
# sourcing it there would silently test stale or absent functions.
sed -n '1,/^LOG "Detecting GPS devices/p' \
    /Users/eighmy/repos/PineapplePager/payloads/.worktrees/gps-ttff-logging/library/user/general/wardrive_activate/payload.sh \
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

echo "== _ttff_kill_previous_poller: dead PID is left alone, no error =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_dead.pid
sh -c 'exit 0' &
dead_pid=$!
wait "$dead_pid" 2>/dev/null
echo "$dead_pid" > "$TTFF_PID_FILE"
_ttff_kill_previous_poller
echo "PASS: _ttff_kill_previous_poller completed without error on a dead PID"

echo "== _ttff_kill_previous_poller: live PID is killed =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_live.pid
sleep 30 &
live_pid=$!
echo "$live_pid" > "$TTFF_PID_FILE"
_ttff_kill_previous_poller
sleep 0.2
if kill -0 "$live_pid" 2>/dev/null; then
    echo "FAIL: previous live poller was not killed"
    kill "$live_pid" 2>/dev/null
    exit 1
else
    echo "PASS: previous live poller was killed"
fi

echo "== _ttff_record_poller_pid: writes the given PID to TTFF_PID_FILE =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_record.pid
rm -f "$TTFF_PID_FILE"
_ttff_record_poller_pid 777
assert_eq "pid file contains the recorded pid" "777" "$(cat "$TTFF_PID_FILE")"

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

echo "== start_ttff_poller: kills a still-live previous poller BEFORE recording the new PID =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_out_order.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_order.pid
TTFF_POLL_TIMEOUT=1
TTFF_POLL_INTERVAL=1
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
sleep 30 &
old_live_pid=$!
echo "$old_live_pid" > "$TTFF_PID_FILE"
gpspipe() { :; }
start_ttff_poller "wardrive_activate" "no"
new_pid="$(cat "$TTFF_PID_FILE")"
if [ "$new_pid" = "$old_live_pid" ]; then
    echo "FAIL: pid file still holds the old poller's pid"
    kill "$old_live_pid" 2>/dev/null
    exit 1
fi
if kill -0 "$old_live_pid" 2>/dev/null; then
    echo "FAIL: old poller was not killed by start_ttff_poller"
    kill "$old_live_pid" "$new_pid" 2>/dev/null
    exit 1
else
    echo "PASS: old poller was killed and pid file now holds the new poller's pid"
fi
wait "$new_pid" 2>/dev/null
assert_eq "new poller logged a timeout line" \
    "2026-08-19T04:23:32Z wardrive_activate injected=no ttff=timeout(1s)" \
    "$(cat "$TTFF_LOG_FILE")"

echo "== start_ttff_poller: does not hold the caller's stdout/stderr open =="
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_fdtest.pid
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_fdtest.log
TTFF_POLL_TIMEOUT=30
TTFF_POLL_INTERVAL=5
rm -f "$TTFF_PID_FILE" "$TTFF_LOG_FILE"
gpspipe() { :; }  # never returns a fix - poller stays alive the full 30s if not fixed
fifo=/tmp/gps_ttff_tests/wa_fdtest.fifo
readerdone=/tmp/gps_ttff_tests/wa_fdtest.reader_done
readerrc=/tmp/gps_ttff_tests/wa_fdtest.reader_rc
rm -f "$fifo" "$readerdone" "$readerrc"
mkfifo "$fifo"
# Open the read end in the background FIRST: opening a FIFO for write blocks
# until a reader is present, so the reader must already be waiting before
# start_ttff_poller's redirect opens the write end below.
( timeout 5 cat "$fifo" >/dev/null; echo $? > "$readerrc"; touch "$readerdone" ) &
reader_pid=$!
sleep 0.3
( start_ttff_poller "wardrive_activate" "no" >"$fifo" 2>&1 )
# start_ttff_poller itself returns immediately either way (it backgrounds the poller).
# The bug is that the backgrounded child keeps a dup of the fifo's write end open,
# so the fifo never sees a final close and the reader never gets EOF. Poll (bounded)
# for the reader to finish; if it doesn't finish promptly with rc=0 (clean EOF before
# its own timeout), the poller is still holding the write end open.
waited=0
while [ ! -f "$readerdone" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
done
if [ -f "$readerdone" ] && [ "$(cat "$readerrc" 2>/dev/null)" = "0" ]; then
    echo "PASS: fifo reached EOF promptly, poller does not hold stdout/stderr open"
else
    echo "FAIL: reading from fifo timed out - poller is still holding stdout/stderr open"
    kill "$(cat "$TTFF_PID_FILE" 2>/dev/null)" 2>/dev/null
    kill "$reader_pid" 2>/dev/null
    rm -f "$fifo" "$readerdone" "$readerrc"
    exit 1
fi
kill "$(cat "$TTFF_PID_FILE" 2>/dev/null)" 2>/dev/null
kill "$reader_pid" 2>/dev/null
rm -f "$fifo" "$readerdone" "$readerrc"

echo "== _ttff_poll_and_log: elapsed reflects real wall-clock time, not just sleep durations =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_wallclock.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_wallclock.pid
TTFF_POLL_TIMEOUT=30
TTFF_POLL_INTERVAL=10
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
# Simulates gpspipe blocking for ~2 real seconds before returning a hit on
# the very FIRST iteration - the loop's `sleep "$TTFF_POLL_INTERVAL"` never
# runs, so a sleep-only elapsed accumulator would log ttff=0s even though
# ~2 real seconds actually passed. This is exactly the undercounting bug
# the wall-clock (`date +%s`) accounting fixes.
gpspipe() { sleep 2; echo '{"class":"TPV","mode":3}'; }
# The real `timeout` binary execve()s its target directly, so it can
# never see gpspipe when gpspipe is a shell function (same limitation
# documented for ubx_write_frame in payload.sh) - swap in a plain
# passthrough here so this call actually reaches the stubbed gpspipe.
# gpspipe's own `sleep 2` already bounds this to ~2s, so no hard timeout
# of its own is needed.
timeout() { shift; "$@"; }
before="$(command date +%s)"
_ttff_poll_and_log "wardrive_activate" "no"
after="$(command date +%s)"
unset -f timeout
real_elapsed=$((after - before))
logged_ttff="$(grep -o 'ttff=[0-9]*s' "$TTFF_LOG_FILE" 2>/dev/null | grep -o '[0-9]*')"
if [ -z "$logged_ttff" ]; then
    echo "FAIL: no numeric ttff value logged (got: $(cat "$TTFF_LOG_FILE" 2>/dev/null))"
    exit 1
elif [ "$logged_ttff" -lt 1 ]; then
    echo "FAIL: logged ttff=${logged_ttff}s undercounts - gpspipe alone took ~2 real seconds"
    exit 1
elif [ $(( real_elapsed - logged_ttff )) -gt 2 ] 2>/dev/null || [ $(( real_elapsed - logged_ttff )) -lt -2 ] 2>/dev/null; then
    echo "FAIL: logged ttff=${logged_ttff}s is not close to the real measured ${real_elapsed}s"
    exit 1
else
    echo "PASS: logged ttff=${logged_ttff}s reflects real wall-clock time (measured ${real_elapsed}s)"
fi

echo "== _ttff_poll_and_log: clears TTFF_PID_FILE on exit if it still names this process =="
TTFF_LOG_FILE=/tmp/gps_ttff_tests/wa_pidclear.log
TTFF_PID_FILE=/tmp/gps_ttff_tests/wa_pidclear.pid
TTFF_POLL_TIMEOUT=1
TTFF_POLL_INTERVAL=1
rm -f "$TTFF_LOG_FILE" "$TTFF_PID_FILE"
gpspipe() { :; }  # no fix ever arrives - forces the timeout path
echo "$$" > "$TTFF_PID_FILE"   # simulate this process having recorded its own pid
_ttff_poll_and_log "wardrive_activate" "no"
if [ -f "$TTFF_PID_FILE" ]; then
    echo "FAIL: TTFF_PID_FILE still exists after _ttff_poll_and_log exited (stale PID left behind)"
    exit 1
else
    echo "PASS: TTFF_PID_FILE was cleared on exit"
fi

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
# integer, or the literal string "timeout". Grouped so 2>/dev/null covers
# a failed *open* of TTFF_LOG_FILE too, not just a post-open write error -
# redirects apply left-to-right, so `cmd >>file 2>/dev/null` alone would
# leak an open failure to the original stderr before the suppression took
# effect.
_ttff_write_result_line() {
    local payload_name="$1" injected="$2" result="$3" ts ttff_field
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$result" = "timeout" ]; then
        ttff_field="timeout(${TTFF_POLL_TIMEOUT}s)"
    else
        ttff_field="${result}s"
    fi
    { echo "${ts} ${payload_name} injected=${injected} ttff=${ttff_field}" >> "$TTFF_LOG_FILE"; } 2>/dev/null
}

# Kills any still-alive poller recorded in TTFF_PID_FILE. Call BEFORE
# spawning a new poller, so a stale poller is never left running
# concurrently with a fresh one.
_ttff_kill_previous_poller() {
    local old_pid
    if [ -f "$TTFF_PID_FILE" ]; then
        old_pid="$(cat "$TTFF_PID_FILE" 2>/dev/null)"
        case "$old_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old_pid" 2>/dev/null && kill "$old_pid" 2>/dev/null ;;
        esac
    fi
}

# Records $1 (a poller's PID) in TTFF_PID_FILE. Call AFTER spawning the
# poller, once its real PID ($!) is known. Grouped so 2>/dev/null covers a
# failed *open* of TTFF_PID_FILE too - unlike _ttff_write_result_line,
# this runs in the caller's foreground context, so an unsuppressed open
# failure would leak a raw shell error into the payload's interactive
# output instead of failing silently.
_ttff_record_poller_pid() {
    { echo "$1" > "$TTFF_PID_FILE"; } 2>/dev/null
}

# Clears TTFF_PID_FILE if it still names this process. Call on every exit
# path of _ttff_poll_and_log so a finished poller never leaves a stale PID
# behind - an uncleared stale PID risks the OS eventually reusing it for
# an unrelated process, which _ttff_kill_previous_poller would then kill.
_ttff_clear_own_pid() {
    [ "$(cat "$TTFF_PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$TTFF_PID_FILE"
}

# Polls gpsd for a 3D fix and logs the result. $1=payload name literal,
# $2=injected (yes|no). Intended to run backgrounded via start_ttff_poller
# - never call directly in the foreground, it can block for up to
# TTFF_POLL_TIMEOUT seconds. Elapsed time is real wall-clock time (via
# `date +%s`), not a sum of sleep durations - each iteration's
# `timeout 3 gpspipe ...` can itself take up to 3 real seconds, and that
# time must count too or the logged ttff value (and the loop's own
# TTFF_POLL_TIMEOUT cap) would systematically undercount real elapsed
# time, defeating the point of comparing these numbers against wall-clock
# hardware baselines.
_ttff_poll_and_log() {
    local payload_name="$1" injected="$2" start elapsed line
    start="$(date +%s)"
    elapsed=0
    while [ "$elapsed" -lt "$TTFF_POLL_TIMEOUT" ]; do
        line=$(timeout 3 gpspipe -w -n 20 2>/dev/null | grep -m1 '"class":"TPV".*"mode":3')
        if [ -n "$line" ]; then
            elapsed=$(( $(date +%s) - start ))
            _ttff_write_result_line "$payload_name" "$injected" "$elapsed"
            _ttff_clear_own_pid
            return
        fi
        sleep "$TTFF_POLL_INTERVAL"
        elapsed=$(( $(date +%s) - start ))
    done
    _ttff_write_result_line "$payload_name" "$injected" "timeout"
    _ttff_clear_own_pid
}

# Spawns the background TTFF poller. $1=payload name literal (e.g.
# "gps-checker"), $2=injected (yes|no). Call immediately after gpsd has
# been (re)started - never blocks the caller. Kills any still-running
# previous poller first, so pollers never overlap. Redirects the poller's
# stdio away from the caller's - without this, a non-interactive caller
# (e.g. a plain SSH command) whose stdout/stderr the poller inherited
# would hang waiting for those streams to close, even though the caller
# itself returns immediately.
start_ttff_poller() {
    local payload_name="$1" injected="$2"
    _ttff_kill_previous_poller
    _ttff_poll_and_log "$payload_name" "$injected" </dev/null >/dev/null 2>&1 &
    _ttff_record_poller_pid "$!"
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
device="$(ls -1 /dev/serial/by-path/* 2>/dev/null | head -n1)"
device="$(readlink -f "$device" 2>/dev/null)"
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
