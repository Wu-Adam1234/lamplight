#!/bin/sh
# Builds Lamplight.app (universal: Apple silicon + Intel) and a zip for releases.
# Usage: scripts/build-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
VERSION="${1:-$(cat VERSION)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/Lamplight.app"

echo "==> Building Lamplight $VERSION ($BUILD)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Lamplight"

echo "==> Rendering icons"
swift scripts/render-icon.swift build/icons > /dev/null
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  cp "build/icons/icon_$s.png" "$ICONSET/icon_${s}x${s}.png"
  d=$((s * 2))
  cp "build/icons/icon_$d.png" "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lamplight"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# Ad-hoc signature: enough for macOS to run it. Not notarized (that needs a paid Apple developer account).
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

ZIP="dist/Lamplight-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "Lamplight-$VERSION.zip" | tee "Lamplight-$VERSION.zip.sha256")
echo "==> Done: $APP and $ZIP"
