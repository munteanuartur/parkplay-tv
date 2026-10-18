#!/bin/bash
# ParkPlay TV — builds an UNSIGNED tvOS .ipa that others install with their own Apple ID,
# without Xcode, using a sideloading tool for Apple TV (e.g. atvloadly).
#   bash make-tv-ipa.sh   → ~/Desktop/ParkPlayTV.ipa
# Author: arturm
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
TV_DIR="$(cd "$TOOLS/.." && pwd)"
DERIVED="$TV_DIR/build/IPA"
OUT="$HOME/Desktop/ParkPlayTV.ipa"
command -v xcodebuild >/dev/null 2>&1 || { echo "✗ Xcode is needed to build the .ipa"; exit 1; }

# With CocoaPods (VLC for the 4K test) the workspace is needed; run `pod install` once.
if [ -f "$TV_DIR/Podfile" ] && [ ! -d "$TV_DIR/Pods" ]; then
  command -v pod >/dev/null 2>&1 || { echo "✗ Install CocoaPods first: brew install cocoapods"; exit 1; }
  ( cd "$TV_DIR" && pod install )
fi
if [ -d "$TV_DIR/ParkPlayTV.xcworkspace" ] && [ -d "$TV_DIR/Pods" ]; then
  SRC=(-workspace "$TV_DIR/ParkPlayTV.xcworkspace")
else
  SRC=(-project "$TV_DIR/ParkPlayTV.xcodeproj")
fi

echo "Building (unsigned)…"
xcodebuild "${SRC[@]}" -scheme ParkPlayTV -configuration Release \
  -sdk appletvos -destination 'generic/platform=tvOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  PRODUCT_BUNDLE_IDENTIFIER=com.example.parkplay.tv build -quiet
APP="$DERIVED/Build/Products/Release-appletvos/ParkPlayTV.app"
[ -d "$APP" ] || { echo "✗ build failed"; exit 1; }
TMP="$(mktemp -d -t parkplay-tv-ipa)"
mkdir -p "$TMP/Payload"
cp -R "$APP" "$TMP/Payload/"
rm -f "$OUT"
( cd "$TMP" && zip -qry "$OUT" Payload )
rm -rf "$TMP"
echo "✓ $OUT ($(du -h "$OUT" | cut -f1))"
echo "  Install it on an Apple TV with a sideloading tool for tvOS (e.g. atvloadly) and your own Apple ID."
