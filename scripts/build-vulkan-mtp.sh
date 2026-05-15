#!/bin/bash
# Build llama.cpp with Vulkan + MTP support (gg/spec-mtp-experiments branch)
# Tested on AMD RDNA4 (gfx1201) with RADV Mesa 26.x

set -e

BUILD_DIR="${1:-$HOME/llama-mtp-vulkan}"

echo "Cloning gg/spec-mtp-experiments branch..."
git clone --depth=1 --branch gg/spec-mtp-experiments \
    https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"

cd "$BUILD_DIR"

echo "Configuring with Vulkan..."
cmake -B build \
    -DGGML_VULKAN=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=OFF

echo "Building (using $(nproc) cores)..."
cmake --build build --config Release -j$(nproc) --target llama-server

echo ""
echo "Build complete: $BUILD_DIR/build/bin/llama-server"
echo ""
echo "Spec-type options available:"
"$BUILD_DIR/build/bin/llama-server" --help 2>&1 | grep -A1 'spec-type'
