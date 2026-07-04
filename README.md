# AMD Radeon AI PRO R9700 / RX 9700 — llama.cpp Vulkan Inference Optimization Guide

> RDNA4 (gfx1201) Vulkan 推理优化指南 — benchmark results, tuning parameters & optimization strategies
>
> RDNA4 (gfx1201) Vulkan inference + optimization guide — benchmark results, tuning parameters & optimization strategies

[![GPU](https://img.shields.io/badge/GPU-AMD%20Radeon%20AI%20PRO%20R9700-red)](https://www.amd.com/en/products/graphics/workstations/radeon-ai-pro/r9700.html)
[![Backend](https://img.shields.io/badge/Backend-Vulkan-blue)](https://github.com/ggml-org/llama.cpp)
[![Discussion](https://img.shields.io/badge/Discussion-%2319890-blue)](https://github.com/ggml-org/llama.cpp/discussions/19890)

---

## Hardware / 硬件配置

| Component | Spec |
|---|---|
| GPU | AMD Radeon AI PRO R9700 / RX 9700 — 32GB GDDR6, 256-bit bus (~576 GB/s) |
| CPU | AMD Ryzen 7 5700X (8 cores) |
| OS | Ubuntu 24.04 |
| Driver | RADV Mesa (Vulkan, `gfx1201`, `KHR_cooperative_matrix`) |
| llama.cpp | **Latest master** (build 9870+, Vulkan backend) |
| Key env | `RADV_DEBUG=nocompute` — essential for RDNA4 Vulkan perf |

---

## Models Tested / 已测试模型

| Model | Size | Quant | File Size | MoE active params |
|---|---|---|---|---|
| Qwen3-30B-A3B | 30.53B total | Q4_K_M | ~17.3 GiB | ~5.9B per token |
| Qwen3.6-35B-A3B | 35.51B total | Q4_K | ~20.2 GiB | ~6.5B per token |
| Qwen3.6-27B | 27B dense | Q4_K_M | ~16.3 GiB | 27B (dense) |

> Thanks [Zedbytes](https://github.com/ggml-org/llama.cpp/discussions/19890) for the original 30B-A3B benchmarks on R9700 — the data informed many of the optimizations here.

---

## Benchmark Results / 测试结果

### To reproduce locally / 本地重现

```bash
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build-vk -DGGML_VULKAN=ON -DGGML_CPU=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-vk -j$(nproc) --target llama-bench

RADV_DEBUG=nocompute GGML_VK_VISIBLE_DEVICES=0 \
  ./build-vk/bin/llama-bench \
    -m /path/to/model.gguf \
    -n 512 -p 32 -ngl 999 -fa 1 -b 4096 -ub 512 -r 3
```

### Latest Results (llama.cpp master build 9870, Jul 2026)

#### Qwen3.6-35B-A3B Q4_K (20.21 GiB, 35B-class MoE)

`RADV_DEBUG=nocompute` | `KHR_cooperative_matrix` | `flash-attn on`

| Test | tokens/s | Notes |
|---|---|---|
| **tg128** | **164.6 ± 3.1** | **Fastest recorded R9700 35B result** |
| **tg512** | **164.6 ± 3.1** | Stable across batch sizes |
| tg2048 | 165.0 ± 0.2 | Decode speed unchanged |
| pp32 | 521.6 ± 38.7 | Prefill (short) |
| pp512 | 2901.2 ± 97.8 | Prefill (medium) |

#### Qwen3-30B-A3B Q4_K_M (~17.3 GiB, 30B-class MoE)

(From community benchmarks on same hardware)

| Test | tokens/s | Notes |
|---|---|---|
| **tg128** | **183.5 ± 1.0** | ~86% bandwidth utilization |
| pp512 | 3032.6 ± 23.5 | Prefill |
| pp1024 | 3009.0 ± 25.2 | Prefill |

---

## Optimization Timeline / 优化历程

The R9700's raw decode for 35B-class MoE models improved dramatically over the discussion thread's lifecycle:

| Stage | 35B tg (t/s) | What changed |
|---|---|---|
| Initial (first report) | ~93 | Default llama.cpp settings |
| Master branch update | ~105 | Updated to latest llama.cpp |
| `RADV_DEBUG=nocompute` | ~127 | Disabled compute queue for RDNA4 |
| `KHR_cooperative_matrix` support | **~138** | Official deployment speed (llama-server API) |
| llama-bench optimized | **~165** | Benchmark peak with latest build |

> From ~93 to ~165 t/s — **~77% improvement** through software optimizations alone.

---

## ✅ Optimizations That Work / 有效的优化项

### Must-have: `RADV_DEBUG=nocompute`

**The single most impactful setting for RDNA4 gfx1201 Vulkan inference.** This environment variable disables compute queue usage and routes all work through the graphics queue, which on RADV for RDNA4 avoids a performance regression in certain kernel dispatch paths.

```yaml
environment:
  - GGML_VK_VISIBLE_DEVICES=0
  - RADV_DEBUG=nocompute
```

Without this: ~120 t/s → With this: **~138 t/s** (+15%)

### Use latest llama.cpp master

The `KHR_cooperative_matrix` extension support in the Vulkan backend was added in recent llama.cpp builds. The Docker image should be rebuilt periodically against the latest master.

Older builds (e.g. May 2026) without this support benchmark at ~117-120 t/s vs **~165 t/s** with the latest master.

### System-level / 系统级

```bash
# PCIe ASPM performance mode — +~10% decode
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy

# GPU power to high — stable clock speed
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
```

> Note: resets on reboot. See [`scripts/system-optimize.sh`](scripts/system-optimize.sh) for a persistent setup.

### Docker container: pass host Mesa Vulkan drivers

Mount the host's `/dev/dri` and use the same Mesa version as the host for best compatibility:

```yaml
devices:
  - /dev/dri:/dev/dri
group_add:
  - video
```

### llama-server flags / 推理参数 (35B MoE)

```bash
llama-server \
  --model Huihui-Qwen3.6-35B-A3B-Q4_K.gguf \
  --n-gpu-layers 999 \
  --ctx-size 32768 \
  --flash-attn on \
  -b 4096 \
  -ub 512 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0
```

> For 35B MoE models, `-b 4096 -ub 512` is optimal. MTP (`--spec-type draft-mtp`) showed **no benefit** on 35B-A3B and actually regressed performance (~105 vs ~138 t/s), so it is not recommended for this model.

### Dual GPU: R9700 × 2

(From community reports) Two R9700s in x8/x8 PCIe split:
- pp (prefill): **+36%**
- tg (decode): **-25%** (bandwidth split across PCIe hurts MoE decode)

**Recommendation: single R9700 for MoE models.**

---

## ❌ Optimizations That Don't Work / 无效或负优化项 (35B MoE)

| Optimization / 项目 | Result / 结果 | Reason / 原因 |
|---|---|---|
| **MTP (`--spec-type draft-mtp`)** | tg **-24%** (~105 vs ~138) | 35B-A3B MTP head adds overhead without acceptance gain; only useful on dense 27B model |
| AMDVLK driver | pp degrades | prefill drops significantly, not recommended for chat workloads |
| ROCm backend (HIP) | Slower than Vulkan | RDNA4 RADV Vulkan outperforms ROCm HIP by ~20% on this arch |
| Turboquant (turbo2/3/4) | Slower than q4_0 | CPU becomes decompression bottleneck, GPU utilization drops to ~30% |
| `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` | No effect | Already handled by `RADV_DEBUG=nocompute` |
| Dual GPU | tg **-25%** | PCIe split hurts MoE decode more than it helps |

---

## Docker Setup / Docker 部署

### Build the image

```bash
# Clone latest llama.cpp
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

# Configure with Vulkan
cmake -B build -DGGML_VULKAN=ON -DGGML_CPU=ON -DCMAKE_BUILD_TYPE=Release

# Build the server binary
cmake --build build -j$(nproc) --target llama-server

# Build minimal Docker image
cat > Dockerfile << 'EOF'
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

docker build -t llama-cpp-vulkan .
```

### Or use Docker Compose

See [`docker-compose.yml`](docker-compose.yml) for a complete ready-to-use example. Add `RADV_DEBUG=nocompute` to the `environment` section.

---

## Optimization Impact Summary / 优化效果汇总

| Optimization | 35B MoE tg | 35B MoE pp | Notes |
|---|---|---|---|
| **Use latest llama.cpp master** | +40% | +15% | `KHR_cooperative_matrix` support |
| **`RADV_DEBUG=nocompute`** | +15% | Minor | RDNA4 gfx1201 must-have |
| PCIe ASPM performance | +10% | +10% | Free, system-level |
| GPU power high | stabilizes | stabilizes | Prevents throttle |
| `--flash-attn on` | negligible | significant | Standard recommendation |
| MTP (`--spec-type draft-mtp`) | **-24%** | N/A | Only for dense models, not MoE |

---

## References / 参考

- [llama.cpp Discussion #19890 — R9700 Performance Study](https://github.com/ggml-org/llama.cpp/discussions/19890)
- [llama.cpp RDNA4 Experiments Discussion #21043](https://github.com/ggml-org/llama.cpp/discussions/21043)
- [llama.cpp Vulkan Backend](https://github.com/ggml-org/llama.cpp)
- [RADV Mesa Driver](https://docs.mesa3d.org/drivers/radv.html)
- [AMD Radeon AI PRO R9700 Specs](https://www.amd.com/en/products/graphics/workstations/radeon-ai-pro/r9700.html)
