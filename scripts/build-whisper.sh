#!/usr/bin/env bash
# Builds whisper.cpp as static libraries (Metal + Accelerate, Apple Silicon)
# and stages the headers/libraries the Swift package links against.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_VERSION="${WHISPER_VERSION:-v1.9.4}"
SRC="$ROOT/vendor/whisper.cpp"
BUILD="$ROOT/vendor/whisper-build"
LIB_OUT="$ROOT/vendor/lib"
HEADERS_OUT="$ROOT/Sources/CWhisper/include"

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required. Install it with: brew install cmake" >&2
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "==> Fetching whisper.cpp $WHISPER_VERSION"
    git clone --depth 1 --branch "$WHISPER_VERSION" https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi

echo "==> Configuring whisper.cpp"
# GGML_NATIVE=OFF keeps the binary portable across all Apple Silicon Macs (the
# default arm64 target is apple-m1). The heavy lifting runs on the GPU via Metal;
# the Metal shaders are embedded in the binary so no Xcode/metal compiler is needed.
cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_ACCELERATE=ON \
    -DGGML_OPENMP=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_SDL2=OFF >/dev/null

echo "==> Building whisper.cpp (this takes a minute the first time)"
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null

echo "==> Staging libraries and headers"
rm -rf "$LIB_OUT"
mkdir -p "$LIB_OUT" "$HEADERS_OUT"
find "$BUILD" -name "*.a" -exec cp {} "$LIB_OUT/" \;
cp "$SRC/include/whisper.h" "$HEADERS_OUT/"
cp "$SRC"/ggml/include/*.h "$HEADERS_OUT/"

for lib in whisper ggml ggml-base ggml-cpu ggml-metal ggml-blas; do
    if [ ! -f "$LIB_OUT/lib$lib.a" ]; then
        echo "Missing expected library lib$lib.a in $LIB_OUT" >&2
        exit 1
    fi
done
echo "==> whisper.cpp ready ($(ls "$LIB_OUT" | tr '\n' ' '))"
