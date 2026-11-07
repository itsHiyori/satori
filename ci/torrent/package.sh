#!/bin/bash
# Builds libSatoriTorrent.a (libtorrent + the Objective-C++ bridge) and the headers for the app target into $1.
set -euo pipefail
DEST="${1:?destination dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
"$HERE/build-libtorrent.sh" "$OUT"
xcrun --sdk iphoneos clang++ -x objective-c++ -std=gnu++17 -fobjc-arc -arch arm64 -mios-version-min=16.0 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -I "$OUT/include" -I "$OUT/boost" -I "$HERE/bridge" \
  -DBOOST_ASIO_NO_DEPRECATED -DTORRENT_NO_DEPRECATE \
  -c "$HERE/bridge/SatoriTorrent.mm" -o "$OUT/SatoriTorrent.o"
mkdir -p "$DEST"
libtool -static -o "$DEST/libSatoriTorrent.a" "$OUT/SatoriTorrent.o" "$OUT/lib/libtorrent-rasterbar.a"
cp "$HERE/bridge/SatoriTorrent.h" "$DEST/"
printf '#import "SatoriTorrent.h"\n' > "$DEST/SatoriBridging.h"
ls -la "$DEST"
