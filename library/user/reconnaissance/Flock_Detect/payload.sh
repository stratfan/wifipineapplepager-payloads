#!/bin/bash
# Title: Flock You - Multi-Signal Detection v9.17
# Description: Continuous BLE scanner for Flock Safety surveillance devices.
#              v9.17 detects on THREE signals, not just device name:
#                1. XUNTONG manufacturer ID 0x09C8 in BLE advertising data
#                   (parsed from `hcidump --raw`) - the strongest Flock tell.
#                2. MAC OUI prefix match against oui_list.txt (Lite-On chipset,
#                   verified Flock/Falcon/Battery prefixes).
#                3. BLE device name substring (FS Ext Battery/Penguin/Pigvision/
#                   Flock) - the v9.16 behavior, kept as a third signal.
#              Most real Flock BLE adverts carry no name (name-only detection in
#              v9.16 missed them); signals 1 and 2 close that gap.
#              Each detection is GPS-tagged from gpsd (NO_GPS when no fix) and
#              written to a companion CSV.
# Author: colonelpanichacks
# Contributors: Claude (Anthropic), Grok (xAI), Brandon Starkweather
# Data Sources: colonelpanichacks/flock-you, deflock.me, GainSec,
#               Ryan O'Horo (FCC research), Will Greenberg (BLE research)
# Version: 9.17
# Category: Reconnaissance

# --- paths --------------------------------------------------------------
SCRIPT_DIR="$(dirname "$0")"
OUI_LIST="${SCRIPT_DIR}/oui_list.txt"
[ -f "$OUI_LIST" ] || OUI_LIST="/root/payloads/user/reconnaissance/Flock_Detect/oui_list.txt"

LOOT_DIR="/root/loot/flock_you"
mkdir -p "$LOOT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOOT_DIR}/flock_hcitool_${TIMESTAMP}.txt"
CSV_FILE="${LOOT_DIR}/flock_gps_${TIMESTAMP}.csv"

RAW_FILE="/tmp/flock_raw.txt"
SCAN_FILE="/tmp/flock_scan.txt"
HITS_FILE="/tmp/flock_hits.txt"
SEEN_FILE="/tmp/flock_seen.txt"
: > "$SEEN_FILE"   # fresh dedup list each run

# --- GPS fix reader (unchanged from v9.16) ------------------------------
# Echoes "lat,lon" for a 2D/3D fix, nothing otherwise. Kept short so a
# detection cycle never stalls on GPS.
get_gps_fix() {
    local json mode lat lon
    json="$(timeout 3 gpspipe -w -n 30 2>/dev/null | grep '"class":"TPV"' | grep '"lat":' | tail -n 1)"
    [ -z "$json" ] && return 1
    mode="$(echo "$json" | jq -r '.mode // 0' 2>/dev/null)"
    case "$mode" in 2|3) ;; *) return 1 ;; esac
    lat="$(echo "$json" | jq -r '.lat // empty' 2>/dev/null)"
    lon="$(echo "$json" | jq -r '.lon // empty' 2>/dev/null)"
    [ -n "$lat" ] && [ -n "$lon" ] || return 1
    echo "${lat},${lon}"
}

# --- detection ----------------------------------------------------------
# Reads $RAW_FILE (hcidump --raw) and $SCAN_FILE (hcitool lescan) and writes
# one line per unique Flock MAC to stdout as:  MAC|SIGNALS|LABEL
# SIGNALS is one or more of MANUF:XUNTONG / OUI:<cat> / NAME joined by '+'.
detect_hits() {
    # Signal 3 (name) from lescan output -> MAC|NAME|<name>
    grep -iE "fs ext battery|penguin|flock|pigvision" "$SCAN_FILE" 2>/dev/null \
      | awk '{ mac=toupper($1); name=$0; sub(/^[^ ]+ /,"",name); print mac"|NAME|"name }' \
      > "$HITS_FILE"

    # Signals 1 (XUNTONG manuf 0x09C8) + 2 (OUI) from raw hcidump.
    # Reassemble multi-line events, walk LE Advertising Reports.
    awk -v ouifile="$OUI_LIST" '
      BEGIN{
        while ((getline l < ouifile) > 0) {
          n=split(l,a,"|"); if(n>=2){ k=toupper(a[1]); gsub(/ /,"",k); cat[k]=a[2]; lbl[k]=a[3] }
        }
      }
      /^[<>]/ { if(b!="") proc(b); b=$0; next }
      { s=$0; gsub(/^ +/,"",s); b=b" "s }
      END{ if(b!="") proc(b) }
      function proc(ev,   t,n2,mac,oui,tags){
        if (ev !~ /^> 04 3E /) return;
        n2=split(ev,t," ");
        if (t[5] != "02") return;                 # LE Advertising Report subevent
        if (n2 < 15) return;
        mac=toupper(t[14]":"t[13]":"t[12]":"t[11]":"t[10]":"t[9]);   # LE -> written
        oui=toupper(t[14]":"t[13]":"t[12]);
        tags="";
        if (index(ev," FF C8 09")>0) tags="MANUF:XUNTONG";
        if (oui in cat) tags=(tags?tags"+":"")"OUI:"cat[oui];
        if (tags!="") print mac"|"tags"|"lbl[oui];
      }
    ' "$RAW_FILE" 2>/dev/null >> "$HITS_FILE"

    # Merge duplicate MACs, combining signal tags; keep first non-empty label.
    awk -F'|' '
      { m=$1;
        if (!(m in seen)) { seen[m]=1; order[++n]=m; tag[m]=$2; lab[m]=$3 }
        else { tag[m]=tag[m]"+"$2; if(lab[m]==""&&$3!="") lab[m]=$3 }
      }
      END{ for(i=1;i<=n;i++) print order[i]"|"tag[order[i]]"|"lab[order[i]] }
    ' "$HITS_FILE"
}

# --- startup ------------------------------------------------------------
LOG yellow "Flock-You v9.17 started at $(date)"
LOG "Multi-signal scan (manuf ID + OUI + name), GPS-tagged..."
LOG "Signal key:"
LOG magenta "  MANUF  XUNTONG 0x09C8 (strongest)"
LOG yellow  "  OUI    MAC prefix match"
LOG cyan    "  NAME   BLE name match"
LOG "----------------------------------"
echo "v9.17 started at $(date)" > "$LOG_FILE"
echo "time,mac,name_or_label,signals,lat,lon" > "$CSV_FILE"
DETECTIONS=0
COUNTER=0

while true; do
    hciconfig hci0 down 2>>"$LOG_FILE"
    hciconfig hci0 reset 2>>"$LOG_FILE"
    hciconfig hci0 up 2>>"$LOG_FILE"

    # Start the raw sniffer first, then active scan, so adverts are captured.
    : > "$RAW_FILE"; : > "$SCAN_FILE"
    timeout 18 hcidump --raw > "$RAW_FILE" 2>>"$LOG_FILE" &
    DUMP_PID=$!
    timeout 18 hcitool lescan --duplicates > "$SCAN_FILE" 2>>"$LOG_FILE" &
    SCAN_PID=$!
    sleep 12
    kill $SCAN_PID 2>/dev/null; kill $DUMP_PID 2>/dev/null
    wait $SCAN_PID 2>/dev/null; wait $DUMP_PID 2>/dev/null

    # One GPS fix per cycle (empty => NO_GPS for this batch).
    CYCLE_GPS="$(get_gps_fix)"

    # Build merged, deduped Flock hits for this cycle.
    detect_hits > /tmp/flock_merged.txt

    # Iterate in the MAIN shell (via redirect, not a pipe) so cross-cycle
    # dedup and counters persist - fixes the v9.16 subshell dedup gap.
    while IFS='|' read -r MAC SIGNALS LABEL; do
        [ -z "$MAC" ] && continue
        if grep -qx "$MAC" "$SEEN_FILE" 2>/dev/null; then continue; fi
        echo "$MAC" >> "$SEEN_FILE"

        CURRENT_TIME=$(date '+%H:%M:%S')
        DESC="${LABEL:-$SIGNALS}"
        if [ -n "$CYCLE_GPS" ]; then
            GPS_TAG="$CYCLE_GPS"; CSV_LAT="${CYCLE_GPS%,*}"; CSV_LON="${CYCLE_GPS#*,}"
        else
            GPS_TAG="NO_GPS"; CSV_LAT=""; CSV_LON=""
        fi
        ENTRY="DECT: $CURRENT_TIME | $MAC | $SIGNALS | $DESC | $GPS_TAG"

        # Color by strongest signal present.
        case "$SIGNALS" in
            *MANUF*)  LOG magenta "$ENTRY" ;;
            *OUI*)    LOG yellow  "$ENTRY" ;;
            *NAME*)   LOG cyan    "$ENTRY" ;;
            *)        LOG "$ENTRY" ;;
        esac
        echo "$ENTRY" >> "$LOG_FILE"
        echo "${CURRENT_TIME},${MAC},\"${DESC}\",\"${SIGNALS}\",${CSV_LAT},${CSV_LON}" >> "$CSV_FILE"

        DETECTIONS=$((DETECTIONS + 1))
        COUNTER=$((COUNTER + 1))
        if [ $((COUNTER % 10)) -eq 0 ]; then
            LOG " "
            LOG magenta "MANUF XUNTONG"
            LOG yellow  "OUI match"
            LOG cyan    "NAME match"
            LOG " "
        fi

        # Haptic + LED on detection.
        if [ -f /sys/class/gpio/vibrator/value ]; then
            echo 1 > /sys/class/gpio/vibrator/value 2>/dev/null
            sleep 0.15
            echo 0 > /sys/class/gpio/vibrator/value 2>/dev/null
        fi
        if ls /sys/class/leds/* >/dev/null 2>&1; then
            LED=$(ls /sys/class/leds/* | head -1)
            echo 1 > "${LED}/brightness" 2>/dev/null
            sleep 0.3
            echo 0 > "${LED}/brightness" 2>/dev/null
        fi
    done < /tmp/flock_merged.txt

    sleep 3
done
exit 0
