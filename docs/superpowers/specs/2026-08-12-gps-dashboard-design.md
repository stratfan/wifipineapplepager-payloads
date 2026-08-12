# GPS Dashboard — Design

## Background

This repo already has `library/user/general/gps-checker`, a diagnostic payload
that figures out *why* GPS isn't producing a fix (no data from gpsd / no
satellites / satellites detected but not decoding nav data / decoding but no
fix yet / fix acquired). It's a troubleshooting tool: run it, get a diagnosis,
fix the physical situation, run it again.

This is a companion payload for the opposite situation: GPS is already
working (or you just want to see what it currently sees) and you want a live,
continuously-updating readout — position, movement, satellite constellation
mix, and time — without re-running a check-again loop by hand.

## Purpose

`gps-dashboard` is a live GPS status display. It shows, refreshed
automatically:

- Connection / fix status (gpsd reachable, device attached, no fix / 2D / 3D)
- Satellite constellation breakdown (per-GNSS used/seen counts)
- Latitude / longitude
- Speed and heading
- UTC date/time

It does not diagnose or attempt to fix anything — that's `gps-checker`'s job.
This payload only displays.

## Platform constraints that shape this design

- `LOG` sends a line to the payload console and returns immediately; there is
  no clear/redraw primitive available to payload scripts. A "live dashboard"
  is therefore a scrolling feed of periodic blocks, newest at the bottom —
  the same visual pattern `gps-checker` and `wardrive_activate` already use,
  just automatic instead of button-driven.
- There is no non-blocking "check if a button was pressed" call.
  `WAIT_FOR_BUTTON_PRESS [button]` blocks until that button is pressed.
  Continuous auto-refresh with a responsive exit therefore has to be built
  out of a bounded wait, not assumed.
- DuckyScript UI commands (`LOG`, `WAIT_FOR_BUTTON_PRESS`, etc.) are real
  binaries under `/usr/bin` that talk to the running pineapple daemon over an
  eventbus. They only behave correctly when launched through the actual
  payload runner (physical Pager UI or Virtual Pager) — invoking them over
  bare SSH outside that context doesn't produce visible output and blocks
  forever on any wait call.

## Interaction model

Launches straight into the live view — no setup dialogs, no configuration.

Loop, each cycle:
1. Sample gpsd (one `gpspipe -w` JSON pull).
2. Print one formatted block via `LOG`.
3. `timeout 2 WAIT_FOR_BUTTON_PRESS B` — if **B** is pressed within the
   window, exit immediately (`exit 0`); on timeout, loop again.

Chosen over a background sampling loop + blocking exit wait: no PID to track,
no `trap`/cleanup needed, and no risk of leaking an orphaned background
process if the payload is killed abnormally. The tradeoff — exit can lag up
to the poll interval — is a good trade for a 2-second interval.

Refresh interval is a variable at the top of the script (default 2s), so it's
one line to tune.

**B** is used to exit (not the DPAD, as `gps-checker` uses) because B is the
platform-wide "cancel/back" convention on the Pager, and this payload has
exactly one action (exit) — no need to spend DPAD directions on it.

## Data source

One `gpspipe -w -n N` JSON sample per cycle, parsed with `jq` — the same
approach already proven for `gps-checker`'s coordinate display.

- **Connection / device / fix status** — whether `gpspipe` can reach gpsd at
  all, whether a `DEVICES` report lists an attached device, and `TPV.mode`
  (1 = no fix, 2 = 2D, 3 = 3D).
- **Position** — `TPV.lat` / `TPV.lon`, blanked to "no fix" when mode < 2.
- **Speed & heading** — `TPV.speed` (m/s, displayed converted to km/h) and
  `TPV.track` (degrees true), displayed with a computed compass-point letter
  (e.g. `184° (S)`) for quick reading.
- **UTC date/time** — `TPV.time` (ISO 8601), split for display into a time
  portion (date shown too when it's available).
- **Constellation breakdown** — `SKY.satellites`, grouped by `gnssid`
  (confirmed present per-satellite on this device's gpsd 3.25) into
  used/seen counts per constellation, e.g. `GPS 6/8 used  GLONASS 2/3 used`.
  This is an aggregate count, not a per-satellite table — matches the
  aggregated style `gps-checker` already uses and keeps a single block
  readable on the Pager's small screen.

## Display format

One block per refresh cycle, e.g.:

```
[02:38:33 UTC] FIX: 3D
Lat/Lon: 33.464887, -86.612452
Speed: 1.2 km/h  Heading: 184° (S)
Sats: GPS 6/8 used  GLONASS 2/3 used
```

When there's no fix yet, the block still shows connection/satellite state;
position/speed/heading fields show a "no fix" placeholder instead of stale
or zeroed values.

## Error handling

- `gpsd` unreachable: print a single "gpsd: DOWN" line each cycle. No
  restart attempt — diagnosis/repair is `gps-checker`'s responsibility, not
  this payload's.
- Device attached but no fix: this is normal operating state, not an error —
  show satellite/connection info with position fields blanked.
- Exit always returns 0. The Pager's payload runner treats any non-zero exit
  as an execution error and surfaces it to the user as a failure banner; this
  payload has no failure state that isn't already communicated in-line via
  `LOG`, so it must always exit clean. (Lesson learned the hard way fixing
  `gps-checker` — see its git history.)

## File layout

```
library/user/general/gps-dashboard/
├── payload.sh
└── README.md
```

Header block follows repo convention:

```
# Title: GPS Dashboard
# Description: Live-updating GPS status: connection/fix state, constellation
#   breakdown, position, speed/heading, and UTC time.
# Author: KJ4M
# Version: 1.0
# Category: general
```

## Testing plan

1. `bash -n` syntax check.
2. Unit-test the jq/parsing logic against captured/synthetic gpsd JSON
   samples covering: gpsd down, device with no fix, device with a 2D/3D fix,
   multi-constellation SKY report.
3. Shim `LOG` / `WAIT_FOR_BUTTON_PRESS` as plain bash functions (as done for
   `gps-checker`), source the real deployed script's functions, and run them
   against live `gpsd` on the device over SSH to validate real output against
   real device state without needing physical button presses.
4. Deploy to `/root/payloads/user/general/gps-dashboard/` and do a real
   on-device run through the actual payload menu, confirming the B-button
   exit returns cleanly (exit 0) and the display reads sensibly both with
   and without a current fix.

## Out of scope

- No logging to a file — this is a live display only. (`wardrive_activate`
  already owns Wigle-format logging.)
- No configuration UI (refresh interval, units) — a single tunable variable
  in the script is enough; this isn't a payload that needs first-run setup.
- No per-satellite detail table — aggregate constellation counts only.
