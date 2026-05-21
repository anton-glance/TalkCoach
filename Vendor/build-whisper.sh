#!/usr/bin/env bash
# build-whisper.sh — builds libwhisper.a and ggml component libs from the
# whisper.cpp submodule. Run once after cloning or updating the submodule.
# Idempotent: CMake detects unchanged sources and skips recompilation.
#
# Prerequisites: CMake 3.21+, Xcode command-line tools installed.
#
# Usage: bash Vendor/build-whisper.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/Vendor/build"
SRC_DIR="$REPO_ROOT/Vendor/whisper.cpp"

echo "whisper.cpp source: $SRC_DIR"
echo "Build output:       $BUILD_DIR"

cmake -B "$BUILD_DIR" -S "$SRC_DIR" \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=Apple \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --config Release -j"$(sysctl -n hw.logicalcpu)"

echo ""
echo "Build complete. Artifacts:"
echo "  $BUILD_DIR/src/libwhisper.a"
echo "  $BUILD_DIR/ggml/src/libggml.a"
echo "  $BUILD_DIR/ggml/src/libggml-base.a"
echo "  $BUILD_DIR/ggml/src/libggml-cpu.a"
echo "  $BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a"
echo "  $BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"
