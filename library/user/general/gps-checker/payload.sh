#!/bin/bash
# Title: GPS Checker
# Author: mik
# Description: Diagnoses GPS status step by step - data flow, satellite detection, nav decode, and fix - and explains the likely cause at each stage. Caches fixes and primes the receiver for a faster next start.
# Version: 2.1
# Category: general

SAMPLE_SECS=6

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
    local lat="$1" lon="$2" alt="$3" eph="$4" last now
    [ -n "$lat" ] && [ -n "$lon" ] || return
    last="$(PAYLOAD_GET_CONFIG "$HOTSTART_NS" "ts" 2>/dev/null)"
    now="$(date -u +%s)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ "$((now - last))" -ge 60 ] || return   # rate-limit flash writes
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "lat" "$lat" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "lon" "$lon" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "alt" "$alt" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "eph" "$eph" >/dev/null 2>&1
    PAYLOAD_SET_CONFIG "$HOTSTART_NS" "ts" "$now" >/dev/null 2>&1
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
    local year month day hour min sec
    read -r year month day hour min sec <<< "$(date -u '+%Y %m %d %H %M %S')"
    year=$((10#$year))
    if [ "$year" -ge 2020 ] 2>/dev/null && [ "$year" -le 2035 ] 2>/dev/null; then
        flags=$((flags | 0x2 | 0x400))   # time + utc
        month=$((10#$month)); day=$((10#$day)); hour=$((10#$hour))
        min=$((10#$min)); sec=$((10#$sec))
        wno_or_date=$(( (year - 2000) * 100 + month ))
        tow_or_time=$(( day * 1000000 + hour * 10000 + min * 100 + sec ))
        t_acc_ms=2000
    fi

    build_aid_ini "$lat_e7" "$lon_e7" "$alt_cm" "$pos_acc_cm" \
                  "$wno_or_date" "$tow_or_time" "$t_acc_ms" "$flags" || return 1

    [ -c "$device" ] || [ -f "$device" ] || return 1
    local baud
    baud="$(uci -q get gpsd.core.speed)"
    stty -F "$device" ${baud:+"$baud"} raw clocal -echo 2>/dev/null

    # `timeout N ubx_write_frame ...` cannot work: ubx_write_frame is a
    # bash function, not an executable, and timeout always execve()s its
    # target directly rather than going through a shell, so it can never
    # find a shell function by name. Bound the write with a pure-bash
    # background job + watchdog kill instead - a backgrounded job is
    # forked, not exec'd, so it inherits the full function table and
    # variable state (including the _ubx_frame_bytes array build_aid_ini
    # just populated).
    local wpid kpid
    ubx_write_frame "$device" 2>/dev/null &
    wpid=$!
    ( sleep 2; kill -9 "$wpid" 2>/dev/null ) 2>/dev/null &
    kpid=$!
    if wait "$wpid" 2>/dev/null; then
        kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
        return 0
    fi
    kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
    return 1
}

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

# Parses a window of raw NMEA into: unique sats seen, unique sats with decoded
# nav data (elevation present), strongest SNR seen, and the latest fix quality.
# GSV satellite groups are (PRN,elevation,azimuth,SNR); a satellite can be
# detected (SNR present) well before its nav data is decoded (elevation present).
parse_nmea() {
    awk -F, '
        /GSV/ {
            n = NF
            gsub(/\*[0-9A-Fa-f]+$/, "", $n)
            for (i = 5; i + 3 <= n; i += 4) {
                prn = $i
                el = $(i + 1)
                snr = $(i + 3)
                if (prn == "") continue
                seen[prn] = 1
                if (el != "") decoded[prn] = 1
                if (snr != "" && (snr + 0) > maxsnr) maxsnr = snr + 0
            }
        }
        /GGA/ { fixq = $7 + 0 }
        END {
            total = 0; dec = 0
            for (p in seen) total++
            for (p in decoded) dec++
            printf "%d %d %d %d\n", total, dec, maxsnr + 0, fixq
        }
    '
}

# Pulls the latest TPV (position) report once a fix is confirmed.
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
    cache_alt="$(echo "$tpv_json" | jq -r '.altHAE // .altMSL // .alt // empty' 2>/dev/null)"
    cache_eph="$(echo "$tpv_json" | jq -r '.eph // empty' 2>/dev/null)"
    cache_fix "$lat" "$lon" "$cache_alt" "$cache_eph"
}

run_check() {
    id=$(START_SPINNER "Sampling...") # Only one word, because of bug in 1.0.4
    raw="$(timeout "$SAMPLE_SECS" gpspipe -r 2>/dev/null)"
    STOP_SPINNER ${id}

    if [ -z "$raw" ]; then
        restart_gpsd
        id=$(START_SPINNER "Sampling...") # Only one word, because of bug in 1.0.4
        raw="$(timeout "$SAMPLE_SECS" gpspipe -r 2>/dev/null)"
        STOP_SPINNER ${id}
    fi

    if [ -z "$raw" ]; then
        LOG red "gpsd is not producing any data."
        LOG red "Check the GPS device/baud in Settings > GPS, the antenna connection, and the hardware itself."
        STATUS=1
        return
    fi

    read -r sats decoded maxsnr fixq <<< "$(echo "$raw" | parse_nmea)"

    if [ "$fixq" -ge 1 ] 2>/dev/null; then
        LOG green "Fix acquired!"
        show_coordinates
        STATUS=0
        return
    fi

    if [ "$sats" -eq 0 ]; then
        LOG yellow "GPS data is flowing, but 0 satellites are visible."
        LOG yellow "Check the antenna connection/orientation, or move somewhere with sky visibility."
    elif [ "$decoded" -eq 0 ]; then
        LOG yellow "$sats satellite(s) detected (best SNR ${maxsnr} dB-Hz), but none are decoding nav data."
        LOG yellow "This is the classic signature of an obstructed view of sky (buildings, trees, indoors, in a pocket)."
        LOG yellow "Move to open sky and check again."
    else
        LOG yellow "$decoded of $sats satellite(s) decoding nav data (best SNR ${maxsnr} dB-Hz), no fix yet."
        LOG yellow "This is real progress - give it another minute or two with a clear view of sky."
    fi
    STATUS=2
}

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
