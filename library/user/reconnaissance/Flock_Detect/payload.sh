#!/bin/bash
# Title: Flock You - Wardrive Mode v9.18
# Description: Continuous BLE scanner for Flock Safety surveillance devices,
#              tuned for driving past cameras.
#              Detection (unchanged from v9.17) fires on THREE signals:
#                MANUF  XUNTONG manufacturer ID 0x09C8 in the advertising data
#                OUI    MAC prefix in oui_list.txt (Lite-On + verified Flock)
#                NAME   BLE name substring (FS Ext Battery/Penguin/Pigvision/Flock)
#              v9.18 changes for drive-bys:
#                - Near-continuous scanning: the adapter is reset ONCE at start
#                  (not every cycle) and there is NO inter-cycle sleep, so the
#                  scan duty cycle goes from ~67% to ~90%. A short 8s window
#                  keeps detection latency low so a brief fly-by is more likely
#                  to land inside an active scan.
#                - Diagnostic all-advert log: EVERY advert seen (not just Flock
#                  matches) is recorded with its manufacturer ID and RSSI to
#                  flock_alladv_<ts>.csv. Drive past a known camera and this log
#                  shows exactly what it broadcasts - the definitive way to tell
#                  a detection gap from a camera that emits no usable BLE.
#              Each detection is GPS-tagged from gpsd (NO_GPS when no fix).
# Author: colonelpanichacks
# Contributors: Claude (Anthropic), Grok (xAI), Brandon Starkweather
# Data Sources: colonelpanichacks/flock-you, deflock.me, GainSec,
#               Ryan O'Horo (FCC research), Will Greenberg (BLE research)
# Version: 9.18
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
ALLADV_FILE="${LOOT_DIR}/flock_alladv_${TIMESTAMP}.csv"

RAW_FILE="/tmp/flock_raw.txt"
SCAN_FILE="/tmp/flock_scan.txt"
ADV_FILE="/tmp/flock_adv.txt"
SEEN_FILE="/tmp/flock_seen.txt"       # detected (Flock) MACs
ALLSEEN_FILE="/tmp/flock_allseen.txt" # every MAC (diagnostic dedup)
: > "$SEEN_FILE"; : > "$ALLSEEN_FILE"

# --- GPS fix reader (unchanged) -----------------------------------------
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

# --- unified advert parser ----------------------------------------------
# Reads RAW (hcidump --raw) + SCAN (hcitool lescan), emits ONE line per
# unique MAC seen this cycle:  MAC|MANUF|RSSI|TAGS|LABEL|NAME
#   MANUF = 0xNNNN company id (or -), RSSI = best (max) dBm this cycle,
#   TAGS  = flock signals (MANUF:XUNTONG / OUI:<cat> / NAME) or empty,
#   LABEL = oui_list label if OUI matched, NAME = BLE name if advertised.
parse_adverts() {
    awk -v ouifile="$OUI_LIST" -v scanfile="$SCAN_FILE" '
      function hx(s,  n,i,c){ n=0; s=toupper(s);
        for(i=1;i<=length(s);i++){ c=substr(s,i,1); n=n*16+(index("0123456789ABCDEF",c)-1) } return n }
      BEGIN{
        while((getline l < ouifile) > 0){ n=split(l,a,"|"); if(n>=2){ k=toupper(a[1]); gsub(/ /,"",k); cat[k]=a[2]; lbl[k]=a[3] } }
        while((getline l < scanfile) > 0){ n=split(l,a," "); if(n>=2){ m=toupper(a[1]); nm=l; sub(/^[^ ]+ /,"",nm);
          if(nm!="(unknown)" && nm!="") name[m]=nm } }
      }
      /^[<>]/ { if(b!="") proc(b); b=$0; next }
      { s=$0; gsub(/^ +/,"",s); b=b" "s }
      END{
        if(b!="") proc(b)
        for(m in seenmac){
          tg=tags[m]
          if(m in name){ low=tolower(name[m]); if(low ~ /fs ext battery|penguin|flock|pigvision/) tg=(tg?tg"+":"")"NAME" }
          printf "%s|%s|%s|%s|%s|%s\n", m, (m in manf?manf[m]:"-"), rssi[m], tg, (m in lbl2?lbl2[m]:""), (m in name?name[m]:"")
        }
      }
      function proc(ev,  t,n2,mac,oui,dl,i,en,ln,ty,comp,r){
        if(ev !~ /^> 04 3E /) return
        n2=split(ev,t," ")
        if(t[5]!="02") return
        if(n2<16) return
        mac=toupper(t[14]":"t[13]":"t[12]":"t[11]":"t[10]":"t[9])
        oui=toupper(t[14]":"t[13]":"t[12])
        dl=hx(t[15]); r=hx(t[n2]); if(r>=128) r=r-256
        seenmac[mac]=1
        if(!(mac in rssi) || r>rssi[mac]) rssi[mac]=r
        i=16; en=16+dl; if(en>n2) en=n2
        while(i < en){
          ln=hx(t[i]); if(ln<=0) break
          ty=toupper(t[i+1])
          if(ty=="FF" && (i+3)<=n2){
            comp="0x" toupper(t[i+3] t[i+2]); manf[mac]=comp
            if(comp=="0x09C8" && index(tags[mac],"MANUF")==0) tags[mac]=(tags[mac]?tags[mac]"+":"")"MANUF:XUNTONG"
          }
          i += ln+1
        }
        if((oui in cat) && index(tags[mac],"OUI")==0){ tags[mac]=(tags[mac]?tags[mac]"+":"")"OUI:"cat[oui]; lbl2[mac]=lbl[oui] }
      }
    ' "$RAW_FILE" 2>/dev/null
}

# --- startup ------------------------------------------------------------
LOG yellow "Flock-You v9.18 (wardrive) started at $(date)"
LOG "Near-continuous scan + all-advert diagnostic log."
LOG "Signal key:"
LOG magenta "  MANUF  XUNTONG 0x09C8 (strongest)"
LOG yellow  "  OUI    MAC prefix match"
LOG cyan    "  NAME   BLE name match"
LOG "----------------------------------"
echo "v9.18 started at $(date)" > "$LOG_FILE"
echo "time,mac,name_or_label,signals,rssi,lat,lon" > "$CSV_FILE"
echo "time,mac,manuf_id,rssi,name" > "$ALLADV_FILE"

# One-time adapter bring-up (not per-cycle - that was the biggest scan gap).
hciconfig hci0 down 2>>"$LOG_FILE"
hciconfig hci0 reset 2>>"$LOG_FILE"
hciconfig hci0 up 2>>"$LOG_FILE"

DETECTIONS=0
COUNTER=0
EMPTY_STREAK=0

while true; do
    : > "$RAW_FILE"; : > "$SCAN_FILE"
    timeout 11 hcidump --raw > "$RAW_FILE" 2>>"$LOG_FILE" &
    DUMP_PID=$!
    timeout 11 hcitool lescan --duplicates > "$SCAN_FILE" 2>>"$LOG_FILE" &
    SCAN_PID=$!
    sleep 8                                   # active scan window
    kill $SCAN_PID 2>/dev/null; kill $DUMP_PID 2>/dev/null
    wait $SCAN_PID 2>/dev/null; wait $DUMP_PID 2>/dev/null

    # Adaptive recovery: if the adapter captured nothing for 2 cycles, reset it.
    if [ ! -s "$RAW_FILE" ]; then
        EMPTY_STREAK=$((EMPTY_STREAK + 1))
        if [ "$EMPTY_STREAK" -ge 2 ]; then
            hciconfig hci0 down 2>>"$LOG_FILE"; hciconfig hci0 reset 2>>"$LOG_FILE"; hciconfig hci0 up 2>>"$LOG_FILE"
            EMPTY_STREAK=0
        fi
        continue
    fi
    EMPTY_STREAK=0

    CYCLE_GPS="$(get_gps_fix)"
    DIAG_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
    CURRENT_TIME="$(date '+%H:%M:%S')"
    if [ -n "$CYCLE_GPS" ]; then GPS_TAG="$CYCLE_GPS"; CSV_LAT="${CYCLE_GPS%,*}"; CSV_LON="${CYCLE_GPS#*,}";
    else GPS_TAG="NO_GPS"; CSV_LAT=""; CSV_LON=""; fi

    parse_adverts > "$ADV_FILE"

    # Main-shell loop (redirect, not pipe) so dedup + counters persist.
    while IFS='|' read -r MAC MANUF RSSI TAGS LABEL NAME; do
        [ -z "$MAC" ] && continue

        # Diagnostic: log every MAC once per run.
        if ! grep -qx "$MAC" "$ALLSEEN_FILE" 2>/dev/null; then
            echo "$MAC" >> "$ALLSEEN_FILE"
            echo "${DIAG_TIME},${MAC},${MANUF},${RSSI},\"${NAME}\"" >> "$ALLADV_FILE"
        fi

        # Detection: only MACs with a Flock signal, once per run.
        [ -z "$TAGS" ] && continue
        if grep -qx "$MAC" "$SEEN_FILE" 2>/dev/null; then continue; fi
        echo "$MAC" >> "$SEEN_FILE"

        DESC="${LABEL:-${NAME:-$TAGS}}"
        ENTRY="DECT: $CURRENT_TIME | $MAC | $TAGS | $DESC | RSSI:$RSSI | $GPS_TAG"
        case "$TAGS" in
            *MANUF*) LOG magenta "$ENTRY" ;;
            *OUI*)   LOG yellow  "$ENTRY" ;;
            *NAME*)  LOG cyan    "$ENTRY" ;;
            *)       LOG "$ENTRY" ;;
        esac
        echo "$ENTRY" >> "$LOG_FILE"
        echo "${CURRENT_TIME},${MAC},\"${DESC}\",\"${TAGS}\",${RSSI},${CSV_LAT},${CSV_LON}" >> "$CSV_FILE"

        DETECTIONS=$((DETECTIONS + 1))
        COUNTER=$((COUNTER + 1))
        if [ $((COUNTER % 10)) -eq 0 ]; then
            LOG " "; LOG magenta "MANUF XUNTONG"; LOG yellow "OUI match"; LOG cyan "NAME match"; LOG " "
        fi

        if [ -f /sys/class/gpio/vibrator/value ]; then
            echo 1 > /sys/class/gpio/vibrator/value 2>/dev/null; sleep 0.15; echo 0 > /sys/class/gpio/vibrator/value 2>/dev/null
        fi
        if ls /sys/class/leds/* >/dev/null 2>&1; then
            LED=$(ls /sys/class/leds/* | head -1)
            echo 1 > "${LED}/brightness" 2>/dev/null; sleep 0.3; echo 0 > "${LED}/brightness" 2>/dev/null
        fi
    done < "$ADV_FILE"
done
exit 0
