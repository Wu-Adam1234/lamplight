#!/bin/sh
# Builds the Windows app (self-contained, no .NET install needed by users) for x64 and ARM64.
# Works on Windows (Git Bash), macOS and Linux with the official .NET 8 SDK.
# Usage: scripts/build-windows.sh [version]
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:-$(cat VERSION)}"
dotnet test windows/Lamplight.Core.Tests
for RID in win-x64 win-arm64; do
  OUT="dist/windows/$RID"
  rm -rf "$OUT"
  dotnet publish windows/Lamplight.Windows -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -p:Version="$VERSION" -o "$OUT"
  cp LICENSE "$OUT/LICENSE.txt"
  ZIP="dist/Lamplight-$VERSION-windows-${RID#win-}.zip"
  rm -f "$ZIP"
  (cd "$OUT" && zip -q -9 "../../../$ZIP" Lamplight.exe LICENSE.txt) 2>/dev/null || \
    powershell -NoProfile -Command "Compress-Archive -Path '$OUT/Lamplight.exe','$OUT/LICENSE.txt' -DestinationPath '$ZIP' -Force"
  echo "==> $ZIP"
done
