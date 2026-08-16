#!/bin/bash
# Title: GPS Checker
# Author: mik
# Description: Diagnoses GPS status step by step - data flow, satellite detection, nav decode, and fix - and explains the likely cause at each stage.
# Version: 2.0
# Category: general

SAMPLE_SECS=6

# Restarts gpsd once, giving the device a moment to settle.
restart_gpsd() {
    LOG yellow "Restarting gpsd..."
    service gpsd restart
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
