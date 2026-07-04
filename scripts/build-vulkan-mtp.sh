#!/bin/bash
# Build llama.cpp with Vulkan for AMD RDNA4 (gfx1201) — use this OR Docker
# Builds from the latest master branch (KHR_cooperative_matrix required)
# Tested on AMD RDNA4 (gfx1201) with RADV Mesa Vulkan

set -e

BUILD_DIR="${1:-$HOME/llama-mtp-vulkan}"

echo "=== Cloning latest llama.cpp master ==="
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"

cd "$BUILD_DIR"

echo "=== Configuring with Vulkan + CPU ==="
cmake -B build \
    -DGGML_VULKAN=ON \
    -DGGML_CPU=ON \
    -DCMAKE_BUILD_TYPE=Release

echo "=== Building (using $(nproc) cores) ==="
cmake --build build --config Release -j$(nproc) --target llama-server

echo ""
echo "=== Build complete ==="
echo "  Binary:    $BUILD_DIR/build/bin/llama-server"
echo "  Libraries: $BUILD_DIR/build/bin/"
echo ""
echo "=== Build Docker image (optional) ==="
echo 'cat > Dockerfile << "EOF"
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libc6 libstdc++6 libvulkan1 && rm -rf /var/lib/apt/lists/*
COPY build/bin/llama-server /app/llama-server
COPY build/bin/libggml-*.so* /app/
COPY build/bin/libllama*.so* /app/
ENV GGML_VK_VISIBLE_DEVICES=0
ENV RADV_DEBUG=nocompute
WORKDIR /app
ENTRYPOINT ["/app/llama-server"]
EOF
docker build -t llama-cpp-vulkan .'
echo ""
echo "=== Run with RADV_DEBUG=nocompute ==="
echo 'docker run --rm --device /dev/dri:/dev/dri --group-add video \
  -e GGML_VK_VISIBLE_DEVICES=0 -e RADV_DEBUG=nocompute \
  -v /path/to/models:/models \
  -p 8080:8080 llama-cpp-vulkan \
  --model /models/model.gguf --host 0.0.0.0 --port 8080 \
  --n-gpu-layers 999 --ctx-size 32768 --flash-attn on -b 4096 -ub 512'
