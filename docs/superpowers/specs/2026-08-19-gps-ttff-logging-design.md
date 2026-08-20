# GPS TTFF Logging — Design Spec

## Summary

The GPS hot-start feature (UBX-AID-INI, merged in `2026-08-15-gps-hotstart-design.md`) was validated on real hardware: a genuine coldstart-wiped baseline took 305s to first 3D fix, and a coldstart-wiped + AID-INI-injected run took 165s — a 140s (46%) improvement. That validation was a manual, one-off test. This feature adds passive TTFF (time-to-first-fix) logging so the benefit can be observed automatically across real wardriving sessions, without any manual test setup.

## Scope

TTFF logging is added to `gps-checker` and `wardrive_activate` only.

`gps-dashboard` is explicitly out of scope: it never restarts gpsd itself (it only writes the hot-start cache via `cache_fix()` and displays live status), so it has no gpsd-restart event to measure TTFF from. This was confirmed by the existing code comment in `gps-dashboard/payload.sh`: "the payload only writes the cache; it never restarts gpsd itself."

## Architecture

Both `gps-checker` and `wardrive_activate` already have a point where gpsd is (re)started:

- `wardrive_activate`: right after its `/etc/init.d/gpsd start` call (payload.sh, currently line 333), following the `inject_hotstart` call at line 331.
- `gps-checker`: inside `restart_gpsd()`, right after `service gpsd start`.

At that point, each spawns a detached background subshell (`_ttff_poll_and_log ... </dev/null >/dev/null 2>&1 &`) that:

1. Records the poll start.
2. Polls `gpspipe -w` for a `TPV` report with `mode:3`, every 5s, up to a 600s cap. This reuses the exact fix-detection pattern (`gpspipe -w` + mode-3 check) already validated live against real hardware.
3. Appends one line to `/root/wardrive_ttff.log` on success (elapsed seconds) or on hitting the 600s cap (timeout marker).

The payload script itself never blocks on this — `wardrive_activate` proceeds immediately to `WIGLE_START` and its confirmation dialog; `gps-checker`'s on-screen retry loop is likewise unaffected.

An earlier version of this doc claimed plain `... &` (no `nohup`/`disown`) was sufficient for a non-interactively-run payload.sh, based on manual hardware testing. That claim was disproven by later hardware verification: without redirecting stdin/stdout/stderr, the backgrounded poller inherits the caller's file descriptors, so anything waiting for those *streams* to close (not just the calling process to exit) — confirmed via a plain non-pty `ssh host 'restart_gpsd'` — hung for up to `TTFF_POLL_TIMEOUT` (default 600s), even though the real work finished in about a second. The poller writes its results to `$TTFF_LOG_FILE` via an explicit `>>` redirect and never needs the inherited descriptors, so `_ttff_poll_and_log ... </dev/null >/dev/null 2>&1 &` closes them off with no functional effect on the poller itself.

Since this repo has no shared library and duplicates hot-start logic per payload already (see `gps-hotstart-design.md`), the poller function is duplicated into both files following that same convention — not factored into a new shared file.

### Preventing overlapping pollers

`restart_gpsd()` in `gps-checker` can be invoked more than once per session (each "check again" retry that finds a stalled gpsd). `wardrive_activate` could similarly be re-run in a session. To prevent multiple pollers stacking up and watching the same gpsd concurrently:

- Before spawning, check `/tmp/ttff_poller.pid`. If it names a still-alive PID, kill it.
- After spawning, overwrite `/tmp/ttff_poller.pid` with the new poller's PID.

This is a simple last-writer-wins guard, not a general locking primitive — sufficient because only one gpsd instance exists on the device at a time, so only one poller ever needs to be watching it.

### Interaction with Wigle logging

No interaction. The TTFF poller only reads from gpsd via `gpspipe -w` (read-only), the same way Wigle's own GPS polling does, and writes only to its own file. Wigle's CSV logging (`WIGLE_START`) writes to its own separate file. Neither touches the other's file or process.

## Log format

Plain text, one line per completed poll (success or timeout), appended to `/root/wardrive_ttff.log`:

```
2026-08-19T04:23:32Z wardrive_activate injected=no ttff=305s
2026-08-19T04:28:04Z wardrive_activate injected=yes ttff=165s
2026-08-19T05:02:11Z gps-checker injected=yes ttff=timeout(600s)
```

Fields:

- **Timestamp** — UTC, `date -u +%Y-%m-%dT%H:%M:%SZ`, taken when the line is written (fix found, or timeout fires), not when polling started. Keeps the file in write-chronological order.
- **payload** — literal `wardrive_activate` or `gps-checker`, identifying which flow produced the line, since both payloads share this one file.
- **injected** — `yes`/`no`, taken directly from `inject_hotstart`'s return code (0 → yes; 1 → no, e.g. no cache existed yet or the write failed).
- **ttff** — `<N>s` on success, or `timeout(600s)` if no 3D fix appeared within the 600s poll cap.

The 600s cap matches the timeout used during hardware validation testing and comfortably exceeds both the measured cold (305s) and warm (165s) TTFF figures, while still bounding a stuck poller (dead antenna, GPS-hostile environment) to a fixed lifetime instead of running indefinitely.

## Error handling

- `inject_hotstart` failing or no-op'ing (no cache present) is not an error for this feature — it's simply logged as `injected=no`, same as today's behavior where `inject_hotstart`'s callers must proceed to a normal gpsd start regardless of its return code.
- A poller that never observes a 3D fix within 600s logs a `timeout(600s)` line rather than writing nothing — a dead antenna or prolonged poor sky view becomes a visible, distinct outcome in the log rather than silence.
- If `/root/wardrive_ttff.log` can't be written (e.g. filesystem full), the poller's `>>` append fails silently, consistent with this repo's existing pattern of not surfacing background logging failures to the interactive payload UI (e.g. `PAYLOAD_SET_CONFIG ... >/dev/null 2>&1` in the hot-start cache-write path).

## Testing

- **Log-line formatting**: unit-testable by faking `date` output and asserting the exact line format for both the success and timeout cases.
- **PID-guard logic**: unit-testable by seeding `/tmp/ttff_poller.pid` with a live and a dead PID and asserting the kill-and-overwrite behavior.
- **Fix-polling mechanism itself**: not re-tested here — it reuses the `gpspipe -w` + `mode:3` pattern already proven against real hardware during the hot-start validation test earlier in this project. This spec covers wiring that mechanism into a background poller and log writer, not re-validating fix detection.
