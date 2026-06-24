#!/usr/bin/env bash
# Build Pacer.app (Release) and package it into build/Pacer.dmg
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

echo "▸ Building Pacer.app (Release)…"
xcodegen generate
xcodebuild -project Pacer.xcodeproj -scheme Pacer -configuration Release -derivedDataPath ./build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build >/dev/null

APP="build/Build/Products/Release/Pacer.app"
DMG="build/Pacer.dmg"
[ -d "$APP" ] || { echo "✗ build failed: $APP not found"; exit 1; }

command -v create-dmg >/dev/null 2>&1 || { echo "✗ create-dmg 필요 → brew install create-dmg"; exit 1; }
rm -f "$DMG"

echo "▸ Packaging dmg…"
create-dmg \
  --volname "Pacer" \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 100 \
  --icon "Pacer.app" 150 190 \
  --app-drop-link 390 190 \
  --hide-extension "Pacer.app" \
  "$DMG" "$APP"

echo "✓ $DMG"
echo "  (unsigned — first launch: right-click → Open to bypass Gatekeeper)"
