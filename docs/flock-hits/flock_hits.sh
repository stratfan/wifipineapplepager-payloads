#!/bin/bash
# Title: Flock Hits - WiGLE post-processor
# Description: Filters WiGLE wardrive CSVs against the Flock OUI database and
#              emits a GPS-tagged hit list of likely Flock Safety infrastructure.
#              Companion to the Flock_Detect payload: Flock_Detect covers the
#              BLE side on the Pager, this covers the WiFi side on the analysis
#              machine. A Falcon camera is primarily a WiFi device, so this is
#              the path most likely to locate cameras on a drive.
#
# Usage: ./flock_hits.sh [oui_list.txt] [wigle_csv ...]
#   Defaults: OUI list from the Flock_Detect payload, all CSVs in loot/wigle/
#
# Runs as a single awk pass. The original spawned a subprocess per row and
# took minutes over ~30k rows; this finishes in well under a second.
#
# CONFIDENCE: oui_list.txt mixes high- and low-confidence prefixes.
#   FLOCK_VERIFIED / FLOCK_BATTERY -> high confidence, Flock-specific.
#   LITEON (54 of 69 entries) -> generic chipset vendor used by lots of
#   consumer gear; treat a bare LITEON match as a lead, not a camera.
# The FlockCategory column is emitted so hits can be triaged accordingly.
set -euo pipefail

# Resolve the workspace root by walking up until payloads/library is found, so
# the script works whether it is run from docs/flock-hits/ or via the
# loot/flock_hits.sh symlink.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$SELF"
while [ "$WS" != "/" ] && [ ! -d "$WS/payloads/library" ]; do WS="$(dirname "$WS")"; done
[ -d "$WS/payloads/library" ] || { echo "error: cannot locate workspace root from $SELF" >&2; exit 1; }

DEFAULT_OUI="$WS/payloads/library/user/reconnaissance/Flock_Detect/oui_list.txt"
OUI_LIST="${1:-$DEFAULT_OUI}"
shift || true
if [ "$#" -gt 0 ]; then CSVS=("$@"); else CSVS=("$WS"/loot/wigle/*.csv); fi
[ -f "$OUI_LIST" ] || { echo "error: OUI list not found: $OUI_LIST" >&2; exit 1; }

OUT="$WS/loot/flock_hits_$(date +%Y%m%d_%H%M%S).csv"
mkdir -p "$WS/loot"

awk -v ouifile="$OUI_LIST" -v out="$OUT" '
  BEGIN{
    FS=","
    while((getline l < ouifile) > 0){
      n=split(l,a,"|"); if(n>=2){ k=toupper(a[1]); gsub(/ /,"",k); cat[k]=a[2]; lbl[k]=a[3] }
    }
    print "MAC,SSID,AuthMode,FirstSeen,RSSI,Latitude,Longitude,OUI,FlockCategory,Label" > out
  }
  FNR<=2 { next }                      # skip WigleWifi header + column header
  {
    mac=toupper($1)
    if (length(mac) < 17) next
    oui=substr(mac,1,8)
    if (oui in cat){
      hits++
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,\"%s\"\n", $1,$2,$3,$4,$7,$8,$9,oui,cat[oui],lbl[oui] > out
      seen[oui]++; bycat[cat[oui]]++
    }
  }
  END{
    printf "==> %d Flock OUI matches\n", hits+0
    if (hits+0 > 0) {
      print  "    by category (FLOCK_* = high confidence, LITEON = generic vendor):"
      for(c in bycat) printf "      %-16s %d\n", c, bycat[c]
      print  "    by OUI:"
      for(o in seen) printf "      %-10s %-16s %d\n", o, cat[o], seen[o]
    }
  }
' "${CSVS[@]}"

echo "written: $OUT"
