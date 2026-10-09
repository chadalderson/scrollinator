#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) static LAME MP3 encoder into vendor/lame/{include,lib},
# from the source tarball in vendor/. Skips the work when the library is already there.
# LAME is LGPL; the app's full source ships alongside it, so it can always be relinked.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="3.100"
TARBALL="vendor/lame-$VERSION.tar.gz"
SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
OUT="vendor/lame"
MIN_MACOS="14.0"

[[ -f "$OUT/lib/libmp3lame.a" && -f "$OUT/include/lame.h" ]] && exit 0

if [[ ! -f "$TARBALL" ]]; then
    echo "==> Downloading LAME $VERSION"
    mkdir -p "$(dirname "$TARBALL")"
    curl -sSL -o "$TARBALL" "https://downloads.sourceforge.net/project/lame/lame/$VERSION/lame-$VERSION.tar.gz"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "==> Building LAME $VERSION (arm64 + x86_64)"
for arch in arm64 x86_64; do
    mkdir -p "$WORK/$arch"
    tar -xzf "$TARBALL" -C "$WORK/$arch"
    src="$WORK/$arch/lame-$VERSION"
    # 3.100 lists a symbol that no longer exists; it only matters for the shared library.
    sed -i '' '/lame_init_old/d' "$src/include/libmp3lame.sym"
    # The 2017 configure scripts know Apple Silicon only as "aarch64".
    host=$([[ $arch == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    build=$([[ $(uname -m) == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    (
        cd "$src"
        CC="clang -arch $arch -mmacosx-version-min=$MIN_MACOS" CFLAGS="-O2 -w" \
            ./configure --host="$host" --build="$build" \
            --disable-shared --enable-static --disable-frontend --disable-decoder --disable-dependency-tracking \
            --prefix="$WORK/$arch/install" >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
        make install >/dev/null
    )
done

mkdir -p "$OUT/lib" "$OUT/include"
lipo -create "$WORK/arm64/install/lib/libmp3lame.a" "$WORK/x86_64/install/lib/libmp3lame.a" -output "$OUT/lib/libmp3lame.a"
cp "$WORK/arm64/install/include/lame/lame.h" "$OUT/include/lame.h"
echo "==> LAME ready: $OUT/lib/libmp3lame.a"
