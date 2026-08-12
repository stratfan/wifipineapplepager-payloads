#!/bin/bash
# Title: GPS Dashboard
# Description: Live-updating GPS status display: connection/fix state, satellites, position, speed/heading, UTC time.
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
