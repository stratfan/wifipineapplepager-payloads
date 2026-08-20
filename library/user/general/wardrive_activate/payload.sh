#!/bin/bash
# Title: Wardrive Activate
# Author: TheDadNerd
# Description: Detects GPS devices, configures GPS, and starts Wigle. Primes the receiver with the last known fix for a faster start.
# Version: 1.1
# Category: general

# --- GPS hot-start (UBX-AID-INI) ----------------------------------------
# Shared PAYLOAD_SET_CONFIG/PAYLOAD_GET_CONFIG namespace also used by
# gps-checker and gps-dashboard to cache the last known fix. This payload
# only injects (it doesn't poll fixes itself, so it never writes the
# cache) - see gps-checker/payload.sh for the paired cache_fix writer and
# the full byte-layout rationale (u-blox GPS.G7-SW-12001-B protocol spec
# section 34.8.2). Keep these functions byte-identical to the copies in
# gps-checker - no shared library exists between payload directories on
# this platform.
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
# poller, once its real PID ($!) is known.
_ttff_record_poller_pid() {
    echo "$1" > "$TTFF_PID_FILE" 2>/dev/null
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
# been (re)started - never blocks the caller. Kills any still-running
# previous poller first, so pollers never overlap.
start_ttff_poller() {
    local payload_name="$1" injected="$2"
    _ttff_kill_previous_poller
    _ttff_poll_and_log "$payload_name" "$injected" &
    _ttff_record_poller_pid "$!"
}

# =============================================================================
# INTERNALS: helpers and device detection
# =============================================================================

handle_picker_status() {
    # Normalize DuckyScript dialog exit codes to consistent behavior.
    # This keeps UI exits predictable even if different dialogs are used.
    local status="$1"
    case "$status" in
        "$DUCKYSCRIPT_CANCELLED")
            LOG "User cancelled"
            exit 1
            ;;
        "$DUCKYSCRIPT_REJECTED")
            LOG "Dialog rejected"
            exit 1
            ;;
        "$DUCKYSCRIPT_ERROR")
            ERROR_DIALOG "An error occurred"
            exit 1
            ;;
    esac
}

collect_gps_devices() {
    # Use GPS_LIST output to build a list of USB serial GPS devices.
    # Filter to ttyACM* and ttyUSB* since those are typical GPS device nodes.
    local candidates=()
    local seen=()
    local dev
    local list_output

    list_output="$(GPS_LIST 2>/dev/null)"
    for dev in $(echo "$list_output" | tr ' ' '\n' | grep -E '^/dev/tty(ACM|USB)[0-9]+$' 2>/dev/null); do
        # Avoid duplicate entries in case GPS_LIST returns repeats.
        local already=0
        for existing in "${seen[@]}"; do
            if [[ "$existing" == "$dev" ]]; then
                already=1
                break
            fi
        done
        if [[ "$already" -eq 0 ]]; then
            candidates+=("$dev")
            seen+=("$dev")
        fi
    done
    echo "${candidates[@]}"
}

pick_gps_device() {
    # If multiple devices are found, prompt the user to pick the correct one.
    # If only one device exists, use it without prompting.
    local devices=("$@")
    if [[ "${#devices[@]}" -eq 1 ]]; then
        echo "${devices[0]}"
        return 0
    fi

    # Build a numbered menu list for the Pager dialog prompt.
    MENU="Multiple GPS devices found:\n"
    for i in "${!devices[@]}"; do
        MENU+="\n$((i + 1))) ${devices[$i]}"
    done

    # Show the menu and ensure the dialog succeeded.
    ack=$(PROMPT "$MENU" "")
    handle_picker_status $?

    # Collect the user's numeric selection with bounds.
    choice=$(NUMBER_PICKER "Select GPS device (1-${#devices[@]})" 1)
    handle_picker_status $?

    # Validate selection and convert to zero-based index.
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#devices[@]} )); then
        ERROR_DIALOG "Invalid selection: $choice"
        exit 1
    fi

    echo "${devices[$((choice - 1))]}"
}

# =============================================================================
# MAIN FLOW
# =============================================================================

LOG "Detecting GPS devices..."

# Payload config namespace for persistent settings.
PAYLOAD_NAME="wardrive_activate"

# Load stored baud rate, or prompt the user on first run.
# Use --set-baud to change the saved value on demand.
baud_rate="$(PAYLOAD_GET_CONFIG "$PAYLOAD_NAME" "baud" 2>/dev/null)"
if [[ "$1" == "--set-baud" ]]; then
    # Explicitly update the stored baud rate.
    while :; do
        baud_rate="$(TEXT_PICKER "Enter GPS baud rate (e.g., 4800, 9600, 115200)" "${baud_rate:-9600}")"
        if [[ "$baud_rate" =~ ^[0-9]+$ ]]; then
            break
        fi
        ERROR_DIALOG "Invalid baud rate. Enter numbers only."
    done
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "baud" "$baud_rate"
    shift
elif ! [[ "$baud_rate" =~ ^[0-9]+$ ]]; then
    # First-time setup: confirm the common 9600 baud default.
    RESP=$(CONFIRMATION_DIALOG "Use 9600 baud for GPS?")
    case "$RESP" in
        "$DUCKYSCRIPT_USER_CONFIRMED"|1)
            baud_rate="9600"
            ;;
        "$DUCKYSCRIPT_USER_DENIED")
            # Re-prompt until a numeric baud rate is provided.
            while :; do
                baud_rate="$(TEXT_PICKER "Enter GPS baud rate (e.g., 4800, 9600, 115200)" "")"
                if [[ "$baud_rate" =~ ^[0-9]+$ ]]; then
                    break
                fi
                ERROR_DIALOG "Invalid baud rate. Enter numbers only."
            done
            ;;
        *)
            ERROR_DIALOG "Cancelled."
            exit 1
            ;;
    esac
    # Persist the initial baud rate choice.
    PAYLOAD_SET_CONFIG "$PAYLOAD_NAME" "baud" "$baud_rate"
fi

# Optional device path override from the caller (manual runs can pass a device).
provided_device="$1"

# Prefer a provided device path when present and valid, otherwise auto-detect.
selected_device=""
if [[ -n "$provided_device" && -c "$provided_device" ]]; then
    # Trust the provided device path when it is a valid character device.
    selected_device="$provided_device"
    LOG "Using provided GPS device: $selected_device"
else
    # Prefer the existing configured device from gpsd UCI if it is still present.
    configured_device="$(uci -q get gpsd.core.device 2>/dev/null)"
    # Scan for attached GPS devices using GPS_LIST.
    devices=($(collect_gps_devices))

    # Determine which device should be used this run.
    if [[ -n "$configured_device" && -c "$configured_device" ]]; then
        # Keep the stored device when it is still valid.
        selected_device="$configured_device"
        LOG "Using configured GPS device: $selected_device"
    else
        # If no stored device is valid, require detection or user choice.
        if [[ "${#devices[@]}" -eq 0 ]]; then
            ERROR_DIALOG "No GPS devices found. Check your USB GPS and try again."
            exit 1
        fi
        # Ask the user which device to use when multiple are present.
        selected_device="$(pick_gps_device "${devices[@]}")"
    fi
fi

LOG "Configuring GPS device..."
# Use DuckyScript GPS_CONFIGURE to set the device and stored baud rate.
GPS_CONFIGURE "$selected_device" "$baud_rate" >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Failed to configure GPS device."
    exit 1
fi

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

# Enable Wigle logging now that GPS is configured (no uploads are performed).
LOG "Enabling Wigle logging..."
wigle_file="$(WIGLE_START 2>/dev/null)"
if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Failed to start Wigle logging."
    exit 1
fi
if [[ -n "$wigle_file" ]]; then
    LOG "Wigle log started: $wigle_file"
fi

# Final user-facing confirmation.
ALERT "GPS device set to:\n$selected_device\n\ngpsd configured.\nWigle logging started."
