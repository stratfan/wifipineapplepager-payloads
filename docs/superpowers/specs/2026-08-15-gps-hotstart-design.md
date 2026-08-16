# GPS Hot-Start (UBX-AID-INI) — Design

## Background

The Pager's GPS dongle is a genuine u-blox 7 receiver (confirmed via
`lsusb`: `1546:01a7 u-blox AG - u-blox 7 - GPS/GNSS Receiver`), driven
through `gpsd` 3.25 (`gpsd`, `gpsd-clients`, `gpsd-utils` packages), with the
device/baud/port UCI-configured under `gpsd.core.*`. Nothing in this repo, or
in the platform's DuckyScript surface (`GPS_LIST`, `GPS_CONFIGURE`), seeds the
receiver with a prior position — every start is a cold start, which for a
u-blox 7 without a valid almanac/ephemeris/time hint can take 30s or more to
first fix, especially with a marginal sky view (confirmed absent by grepping
the whole repo for `gpsd|ubxtool|AID-INI|MGA|hot.?start|warm.?start|TTFF`).

u-blox 7 supports `UBX-AID-INI` ("Aiding position, time, frequency, clock
drift" — protocol spec GPS.G7-SW-12001-B §34.8.2, p.92-94), which lets a host
feed the receiver an approximate position and time before/at start-up so it
can narrow its satellite search instead of searching blind. This is the
standard hot/warm-start mechanism for this generation of u-blox chip (AID-*
messages are deprecated on u-blox 8+/M8 in favor of MGA, but this is
confirmed u-blox 7, where AID-INI is the correct, supported message).

No off-the-shelf tool on this platform builds this message: this device's
`gpsd-clients` package ships `gpsctl`/`gpsmon`/`gpspipe`/`gpxlogger`/`cgps`/
`gpsdecode` but no `ubxtool` (a Python script this embedded build doesn't
ship), and even upstream `ubxtool` only *decodes* AID-INI (polls the
receiver's current aiding state) — it has no flag to construct and send a
synthetic one from arbitrary lat/lon/alt/time. This has to be hand-built.

## Purpose

Cut typical time-to-first-fix on repeat GPS use by feeding the receiver the
last known-good position (and, when the system clock looks sane, the current
time) immediately before `gpsd` starts. Fully automatic — no new user-facing
payload, no setup dialog, no configuration.

## Architecture

No shared-library mechanism exists between payload directories in this repo
(each payload directory is self-contained and independently
zipped/installed — confirmed no `shared/`/`common/`/`lib/` precedent anywhere
in repo history). The hot-start logic is therefore duplicated, in full, in
each of the payloads below — kept small and identical so a future fix can be
copy-applied to both.

Two roles:

- **Cache writers** — `gps-checker` and `gps-dashboard`. Both already parse a
  `TPV` JSON report from `gpsd` on every poll (`show_coordinates()` in
  `gps-checker`; the main loop in `gps-dashboard`). Whenever either observes
  a fix (`mode >= 2` with `lat`/`lon` present), it also writes the fix to a
  shared persistent cache. No new polling, no new dependency — this rides on
  data both payloads already pull.
- **Injectors** — `gps-checker`'s `restart_gpsd()` and `wardrive_activate`'s
  GPS-configure-then-restart step (`payload.sh:178-180`), the two places in
  this repo that already call `service gpsd restart` /
  `/etc/init.d/gpsd restart`. Each reads the cache and, if usable, sends the
  aiding message in the gap between stopping and starting `gpsd` (injection
  can't happen while `gpsd` owns the serial port).

`gps-dashboard` never restarts `gpsd` itself, so it's a writer only.
`wardrive_activate` never polls a fix itself, so it's an injector only.
`gps-checker` does both.

## Cache format

Stored via `PAYLOAD_SET_CONFIG` / `PAYLOAD_GET_CONFIG` (this repo's existing
UCI-backed persistent config mechanism — already used by `wardrive_activate`
for its baud-rate setting), under a namespace shared by all three payloads:

```
PAYLOAD_NAME="gps_hotstart"   # shared across gps-checker, gps-dashboard, wardrive_activate

Keys:
  lat   — decimal degrees, e.g. "33.464887"
  lon   — decimal degrees, e.g. "-86.612452"
  alt   — meters (altMSL, falls back to alt if altMSL absent); empty if unknown
  eph   — estimated horizontal position error in meters, from TPV.eph; empty if unknown
  ts    — unix timestamp (seconds) when this fix was captured, from `date +%s`
```

UCI persists across reboots and power cycles, which is the point — the cache
should still be there the next time the Pager is powered on with the same
dongle.

Writer logic (identical in both `gps-checker` and `gps-dashboard`, run right
after a fix's `lat`/`lon` are extracted from the `TPV` JSON):

```bash
cache_fix() {
    local lat="$1" lon="$2" alt="$3" eph="$4"
    [ -z "$lat" ] || [ -z "$lon" ] && return
    PAYLOAD_SET_CONFIG "gps_hotstart" "lat" "$lat"
    PAYLOAD_SET_CONFIG "gps_hotstart" "lon" "$lon"
    PAYLOAD_SET_CONFIG "gps_hotstart" "alt" "$alt"
    PAYLOAD_SET_CONFIG "gps_hotstart" "eph" "$eph"
    PAYLOAD_SET_CONFIG "gps_hotstart" "ts" "$(date -u +%s)"
}
```

Called on every fix, unconditionally overwriting the previous cache — always
keep the freshest observed fix, no history.

## UBX-AID-INI message construction

Verified directly against u-blox's own protocol spec (GPS.G7-SW-12001-B,
"GPS.G7-SW-12001-B" edition, §34.8.2 "Aiding position, time, frequency,
clock drift", p.92-94), including the bitfield diagrams for `tmCfg` and
`flags` (rendered and read visually — these are graphics, not extractable
text, so a plain-text pull of the spec would have missed the bit numbers).

Frame: `B5 62 0B 01 30 00 <48-byte payload> CK_A CK_B` (class `0x0B`,
id `0x01`, length `0x0030` = 48, little-endian throughout).

Payload (48 bytes):

| Offset | Bytes | Format | Field | Scale / Unit | Value we send |
|---|---|---|---|---|---|
| 0 | 4 | I4 (signed) | lat | degrees × 1e7 | `round(cached_lat * 1e7)` |
| 4 | 4 | I4 (signed) | lon | degrees × 1e7 | `round(cached_lon * 1e7)` |
| 8 | 4 | I4 (signed) | alt | cm | `round(cached_alt * 100)`, or `0` if alt unknown |
| 12 | 4 | U4 | posAcc | cm | see "Accuracy fields" below |
| 16 | 2 | X2 | tmCfg | bitfield | `0x0000` — no external time-pulse hardware wired up |
| 18 | 2 | U2 | wnoOrDate | YYMM (utc mode) | `(year-2000)*100 + month`, `0` if time omitted |
| 20 | 4 | U4 | towOrTime | DDHHMMSS (utc mode) | `day*1000000 + hour*10000 + min*100 + sec`, `0` if time omitted |
| 24 | 4 | I4 (signed) | towNs | ns | `0` (no sub-second precision available) |
| 28 | 4 | U4 | tAccMs | ms | see "Accuracy fields" below |
| 32 | 4 | U4 | tAccNs | ns | `0` |
| 36 | 4 | I4 (signed) | clkDOrFreq | — | `0` (unused — neither clockD nor clockF flag set) |
| 40 | 4 | U4 | clkDAccOrFreqAcc | — | `0` (unused) |
| 44 | 4 | X4 | flags | bitmask | see "Flags" below |

**Flags** (bit numbers confirmed from the spec's bitfield diagram, not
inferred from prose order):

- bit0 `pos` — always set (we always have *some* cached position if we're
  injecting at all)
- bit1 `time` — set only if the system-clock sanity check passes (below)
- bit5 `lla` — always set (we send lat/lon/alt, not ECEF X/Y/Z)
- bit10 `utc` — set together with `time` (we send calendar date/time, not
  GPS week/TOW, since we don't want to hand-roll GPS week-number/leap-second
  math)
- all other bits (`clockD`, `tp`, `clockF`, `altInv`, `prevTm`) unset

So `flags` is `0x0021` (pos+lla) when the clock isn't trusted, or `0x0423`
(pos+time+lla+utc) when it is.

**System-clock sanity check** — before setting the `time`/`utc` bits:

```bash
year="$(date -u +%Y)"
[ "$year" -ge 2020 ] 2>/dev/null && [ "$year" -le 2035 ] 2>/dev/null
```

This device has no battery-backed RTC and may not have reached an NTP source
yet in the field. A *wrong* time fed as a confident aiding hint can slow
acquisition (the receiver wastes search budget on a bad hypothesis) — unlike
a stale *position*, which only degrades gracefully. So: position aiding is
sent whenever any cache exists at all; time aiding is sent only when the
clock passes this floor check. The check is intentionally coarse (a decade
window) — it's a guard against clearly-wrong values (epoch, build-date
defaults), not a claim of precision.

**Accuracy fields** — `posAcc` and `tAccMs` tell the receiver how much to
trust the hint; overclaiming precision is worse than underclaiming, since a
falsely-tight value can make the receiver discard nearby-but-different
correct candidates.

- `posAcc`: if the cache has `eph`, use `max(round(eph_meters * 100), 5000)`
  (i.e. the observed accuracy at capture time, floored at 50m so a
  suspiciously-precise cached `eph` doesn't get taken too literally after the
  fact); if `eph` is missing from the cache, fall back to `300000` (3km) —
  wide enough to be honest about an unknown-precision hint while still far
  narrower than "could be anywhere."
- `tAccMs`: fixed at `2000` (2 seconds) whenever the `time` flag is set. Not
  computed from cache age, because the *time* field itself is always
  "system clock right now," not the cached timestamp — its accuracy depends
  on how good this device's clock is, not on how old the cached fix is.

**Checksum**: standard UBX 8-bit Fletcher, computed over class/id/length/
payload (everything after the `B5 62` sync bytes, before the checksum
itself) — confirmed against the spec's own checksum section:

```
CK_A = CK_B = 0
for each byte b in (class, id, lenLo, lenHi, payload...):
    CK_A = (CK_A + b) & 0xFF
    CK_B = (CK_B + CK_A) & 0xFF
```

## Injection procedure

Identical in `gps-checker`'s `restart_gpsd()` and `wardrive_activate`'s
restart step, replacing the current single `service gpsd restart` /
`/etc/init.d/gpsd restart` call:

1. Read `lat`/`lon`/`alt`/`eph`/`ts` via `PAYLOAD_GET_CONFIG "gps_hotstart" ...`.
   If `lat` or `lon` is empty, skip straight to the existing plain restart —
   this is the first-ever run, nothing to inject yet.
2. Resolve the device path the same way `wardrive_activate` already does:
   `uci -q get gpsd.core.device`, following the symlink if it's one of the
   `/dev/serial/by-path/...` entries.
3. `service gpsd stop`.
4. Set the line discipline to the configured baud
   (`stty -F "$device" "$(uci -q get gpsd.core.speed)" raw` — mirrors what
   `/etc/hotplug.d/tty/10-gps` itself does on the real device).
5. Build the 48-byte payload + 6-byte frame as described above and write it
   directly to `$device` (e.g. via `printf`/`dd`), then a brief `sleep` to
   let the receiver process it before gpsd reopens the port.
6. `service gpsd start`.

If any step from 2-5 fails (device path missing, write error), log it at
whatever verbosity the calling payload already uses and fall through to
`service gpsd start` anyway — this feature must never leave `gpsd` stopped
or block the payload's normal flow. A failed injection is a no-op, not a
failure: the receiver just does its normal cold start.

## Error handling

- No cache yet → skip injection silently, plain restart. (First run on a
  Pager, or after `PAYLOAD_DEL_CONFIG`, always falls back to this.)
- Cache present but device path unresolvable → skip injection, plain
  restart.
- Serial write fails → skip remaining injection steps, still run
  `service gpsd start` (never leave gpsd down).
- Malformed/non-numeric cached values (shouldn't happen since only our own
  writer populates this namespace, but a corrupted UCI value is possible) →
  guard with a numeric regex check before use; treat as "no cache" on
  failure.
- This feature adds no new failure mode visible to the user — worst case on
  any error is exactly today's behavior (cold start).

## File layout (files touched, no new payload directories)

```
library/user/general/gps-checker/payload.sh       # writer (show_coordinates) + injector (restart_gpsd)
library/user/general/gps-dashboard/payload.sh      # writer only
library/user/general/wardrive_activate/payload.sh  # injector only
```

Each payload's version comment and README get a short changelog line noting
the hot-start addition; no other repo files change.

## Testing plan

1. `bash -n` syntax check on all three modified `payload.sh` files.
2. Unit-test the pure-logic pieces without hardware:
   - checksum function against known UBX message byte sequences with a
     hand-verified expected `CK_A CK_B` (e.g. an `AID-INI` poll: class
     `0x0B` id `0x01` length `0x0000`, no payload — verifiable against the
     spec by hand, small enough to check by inspection).
   - lat/lon/alt scaling and negative-value (two's-complement) handling for
     southern/western-hemisphere coordinates.
   - flags/tmCfg value selection under: no cache, cache without eph, cache
     with eph, clock-sane, clock-insane.
   - `wnoOrDate`/`towOrTime` YYMM/DDHHMMSS packing against a few known dates.
3. Shim `PAYLOAD_GET_CONFIG`/`PAYLOAD_SET_CONFIG`/`service` as plain bash
   functions (same technique already used for `gps-checker`'s existing
   tests) to exercise the full injector flow (cache hit / cache miss /
   device-resolution failure / write failure) without touching real
   hardware.
4. On-device, over SSH: confirm the constructed bytes for a fixed known
   input match a hand-computed expectation (dump to a file, hexdump,
   compare), *before* ever writing to the live serial device.
5. On-device, live: seed the cache with the Pager's actual last-known
   position, run an injector payload, and confirm via `gpsmon` or a
   `gpspipe` capture that the receiver accepted the aiding data (no
   `ACK-NAK`, and ideally a faster fix than an equivalent cold run with the
   cache cleared via `PAYLOAD_DEL_CONFIG` first). This is the only step that
   can validate an actual TTFF improvement — everything above validates
   correctness, not speed, and this step needs a real open-sky test with
   the physical dongle, which no agent can perform unattended.

## Out of scope

- No new user-facing payload — this is a transparent enhancement to
  existing restart paths.
- No GPS week-number/leap-second math — we always use the UTC date/time
  encoding of `wnoOrDate`/`towOrTime`, never the GPS-week encoding, so this
  is never needed.
- No clock-drift/frequency aiding (`clockD`/`clockF`) — no hardware time
  pulse or disciplined oscillator input exists on this platform to make
  that meaningful.
- No attempt to patch `/etc/hotplug.d/tty/10-gps` or `/etc/init.d/gpsd` for
  a plug-in-triggered hot start — those are Pager firmware files outside
  this repo's scope, and patching them would leave a persistent system
  modification outside the normal payload contribution model (see prior
  discussion in this design's originating conversation). A bare USB
  replug with no payload launched afterward still cold-starts; the user is
  expected to launch a GPS payload after plugging in, as today.
- No manual "prime now" payload — priming is fully automatic, tied to the
  restart paths that already exist.

## Global Constraints

- Every write to the shared `gps_hotstart` PAYLOAD_SET_CONFIG namespace uses
  exactly the keys `lat`, `lon`, `alt`, `eph`, `ts` — all three payloads must
  agree on these names verbatim.
- `flags` bit numbers are fixed by the hardware spec and must not be
  reinterpreted: bit0 `pos`, bit1 `time`, bit5 `lla`, bit10 `utc`.
- `tAccMs` is always `2000` when `time` is set; `posAcc` floors at `5000`
  (50m) when computed from cached `eph`, else `300000` (3km) flat.
- Injection must never leave `gpsd` stopped — every code path through the
  injector ends in `service gpsd start` (or the platform's equivalent),
  including every error/skip path.
- No shared library file — the injector/writer logic is duplicated verbatim
  across `gps-checker`, `gps-dashboard`, and `wardrive_activate`'s
  `payload.sh` files, per this repo's one-directory-per-payload convention.
