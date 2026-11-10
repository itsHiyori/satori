#!/bin/bash
# Builds libtorrent-rasterbar (BSD) as a static library for iOS arm64 without OpenSSL, plus the Boost headers it needs.
# Output: $OUT/lib/libtorrent-rasterbar.a, $OUT/include (libtorrent), $OUT/boost (Boost headers root).
set -euo pipefail
OUT="${1:?output dir}"
LT_TAG="${LT_TAG:-v2.0.11}"
BOOST_VER="${BOOST_VER:-1.86.0}"
WORK="$(mktemp -d)"
mkdir -p "$OUT"
cd "$WORK"

curl -fsSL --retry 3 -o boost.tar.gz "https://archives.boost.io/release/${BOOST_VER}/source/boost_${BOOST_VER//./_}.tar.gz"
tar xzf boost.tar.gz
mv "boost_${BOOST_VER//./_}" boost

git clone --depth 1 --branch "$LT_TAG" --recurse-submodules --shallow-submodules https://github.com/arvidn/libtorrent.git lt

cmake -S lt -B build -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF -Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF \
  -Dencryption=ON -Dwebtorrent=OFF -Dgnutls=OFF -Ddeprecated-functions=OFF \
  -DBOOST_ROOT="$WORK/boost" -DBoost_NO_SYSTEM_PATHS=ON -DBoost_INCLUDE_DIR="$WORK/boost" \
  -DCMAKE_CXX_FLAGS="-DBOOST_ASIO_DISABLE_KQUEUE_EV_EXCEPT"
cmake --build build --target torrent-rasterbar -j "$(sysctl -n hw.ncpu)"

mkdir -p "$OUT/lib" "$OUT/include"
cp "$(find build -name 'libtorrent-rasterbar*.a' | head -1)" "$OUT/lib/libtorrent-rasterbar.a"
cp -R lt/include/libtorrent "$OUT/include/"
# protocol encryption is on (-Dencryption=ON): without it most seeders refuse the connection (2 peers instead of 7 in a test)
# only the headers libtorrent and the bridge include are kept (the full Boost tree is ~700 MB)
mkdir -p "$OUT/boost"
cp -R boost/boost "$OUT/boost/boost"
ls -la "$OUT/lib"
