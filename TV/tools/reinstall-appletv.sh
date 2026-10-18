#!/bin/bash
# ParkPlay TV — recompilează și reinstalează aplicația pe Apple TV.
# Cu un Apple ID gratuit, semnătura expiră după 7 zile; scriptul o reînnoiește.
#
#   bash reinstall-appletv.sh            → reinstalează dacă au trecut 6 zile de la ultima instalare
#   bash reinstall-appletv.sh --force    → reinstalează acum
#
# Opțional:  PARKPLAY_DEVICE="appleTV"  (numele / UDID-ul Apple TV-ului; implicit primul Apple TV găsit)
#            PARKPLAY_DAYS=6
# Jurnal:    ~/Library/Logs/ParkPlayTV-reinstall.log
# Autor: arturm
set -uo pipefail

TV_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
LOG="$HOME/Library/Logs/ParkPlayTV-reinstall.log"
STATE_DIR="$HOME/Library/Application Support/ParkPlayTV"
STAMP="$STATE_DIR/last-install"
DAYS="${PARKPLAY_DAYS:-6}"
DEVICE="${PARKPLAY_DEVICE:-}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo
echo "===== $(date '+%Y-%m-%d %H:%M:%S') ====="

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"ParkPlay TV\"" >/dev/null 2>&1 || true
}

fail() {
  echo "✗ $1"
  notify "Reinstalarea pe Apple TV a eșuat: $1"
  exit 1
}

# 1) E nevoie?
if [ "$FORCE" -eq 0 ] && [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - last ))
  need=$(( DAYS * 86400 - 3600 ))
  if [ "$age" -lt "$need" ]; then
    echo "Instalat acum $(( age / 3600 )) h; următoarea reinstalare după $DAYS zile. Nimic de făcut."
    exit 0
  fi
fi

# 2) Proiectul (poate fi pe un disc extern)
[ -d "$TV_DIR/ParkPlayTV.xcodeproj" ] || fail "nu găsesc proiectul în $TV_DIR (discul e conectat?)"
if [ -d "$TV_DIR/ParkPlayTV.xcworkspace" ]; then
  SRC=(-workspace "$TV_DIR/ParkPlayTV.xcworkspace")
else
  SRC=(-project "$TV_DIR/ParkPlayTV.xcodeproj")
fi

# 3) Apple TV-ul
JSON="$(mktemp -t parkplay-devices).json"
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || fail "devicectl nu răspunde (e instalat Xcode?)"
UDID=$(/usr/bin/python3 - "$JSON" "$DEVICE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
want = sys.argv[2].strip().lower()
for dev in data.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {}) or {}
    props = dev.get("deviceProperties", {}) or {}
    name = (props.get("name") or "").lower()
    ident = (dev.get("identifier") or "")
    udid = (hw.get("udid") or "")
    platform = (hw.get("platform") or "").lower()
    if want:
        if want not in (name, ident.lower(), udid.lower()):
            continue
    elif platform != "tvos":
        continue
    print(udid or ident)
    break
PY
)
rm -f "$JSON"
[ -n "$UDID" ] || fail "nu găsesc Apple TV-ul (e pornit și în aceeași rețea? e împerecheat în Xcode?)"
echo "Apple TV: $UDID"

# 4) Compilare (reînnoiește automat profilul de semnare)
DERIVED="$TV_DIR/build/DerivedData"
echo "Compilez…"
xcodebuild "${SRC[@]}" -scheme ParkPlayTV -configuration Release \
  -destination 'generic/platform=tvOS' -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build -quiet || fail "compilarea a eșuat (vezi jurnalul)"

APP="$DERIVED/Build/Products/Release-appletvos/ParkPlayTV.app"
[ -d "$APP" ] || fail "nu găsesc aplicația compilată"

# 5) Instalare (datele aplicației — favorite, playlisturi — rămân)
echo "Instalez pe Apple TV…"
for attempt in 1 2 3; do
  if xcrun devicectl device install app --device "$UDID" "$APP"; then
    date +%s > "$STAMP"
    echo "✓ ParkPlay TV reinstalat (valabil încă 7 zile)."
    notify "ParkPlay TV a fost reinstalat pe Apple TV."
    exit 0
  fi
  echo "Încercarea $attempt a eșuat; reîncerc în 30 s (Apple TV-ul se poate trezi greu)…"
  sleep 30
done
fail "instalarea pe Apple TV a eșuat"
