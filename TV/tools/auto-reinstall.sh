#!/bin/bash
# ParkPlay TV — pornește / oprește reinstalarea automată pe Apple TV (o dată la 6 zile).
#
#   bash auto-reinstall.sh            → activează (Mac-ul verifică zilnic la 10:07 și 21:07;
#                                       reinstalează când au trecut 6 zile)
#   bash auto-reinstall.sh --remove   → dezactivează
#   bash auto-reinstall.sh --status   → arată starea și ultimele linii din jurnal
# Autor: arturm
set -euo pipefail

LABEL="com.artur.parkplaytv.reinstall"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/reinstall-appletv.sh"
LOG="$HOME/Library/Logs/ParkPlayTV-reinstall.log"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  --remove)
    launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✓ Reinstalarea automată e oprită."
    exit 0
    ;;
  --status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then echo "Activă."; else echo "Oprită."; fi
    STAMP="$HOME/Library/Application Support/ParkPlayTV/last-install"
    [ -f "$STAMP" ] && echo "Ultima instalare: $(date -r "$(cat "$STAMP")" '+%Y-%m-%d %H:%M')"
    [ -f "$LOG" ] && { echo "--- jurnal ---"; tail -n 15 "$LOG"; }
    exit 0
    ;;
esac

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>10</integer><key>Minute</key><integer>7</integer></dict>
        <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>7</integer></dict>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
PL

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "✓ Reinstalarea automată e activă."
echo "  Mac-ul verifică zilnic la 10:07 și 21:07 și reinstalează ParkPlay TV când au trecut 6 zile."
echo "  Dacă Mac-ul doarme la ora aceea, verificarea se face când se trezește."
echo "  Jurnal: $LOG"
echo "  Prima instalare acum:  bash \"$SCRIPT\" --force"
