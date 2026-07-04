# AMD Radeon AI PRO R9700 / RX 9700 — llama.cpp Vulkan Inference Optimization Guide

> RDNA4 (gfx1201) Vulkan 推理优化指南 — 覆盖 27B Dense + 35B MoE 两种模型架构
>
> RDNA4 (gfx1201) Vulkan inference optimization guide — covering 27B Dense + 35B MoE architectures

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

| Model | Architecture | Size | Quant | File Size | Effective params/token |
|---|---|---|---|---|---|
| Qwen3.6-27B | Dense | 27B | Q4_K_M | ~16.3 GiB | 27B (full) |
| Qwen3-30B-A3B | MoE | 30.53B total | Q4_K_M | ~17.3 GiB | ~5.9B |
| Qwen3.6-35B-A3B | MoE | 35.51B total | Q4_K | ~20.2 GiB | ~6.5B |

---

## Benchmark Results / 测试结果

### 1️⃣ Qwen3.6-27B Q4_K_M — Dense Model

> **Optimization path: MTP speculative decoding** — the R9700's 256-bit bus is the bottleneck for dense 27B. MTP boosts effective throughput by accepting ~2 tokens per step. This was the original optimization explored in the project.

#### Before optimization (old llama.cpp, no MTP, old Mesa)

| Test | t/s | Notes |
|---|---|---|
| tg (no MTP) | ~20 | Memory-bandwidth bound dense model |
| pp (1226 tokens) | ~525 | |

#### After optimization (MTP enabled, `-b 16384 -ub 2048`, `--flash-attn on`)

| Test | t/s | Speedup |
|---|---|---|
| **tg (MTP enabled)** | **~42** | **~2× vs no MTP** |
| pp (1226 tokens, ctx 204800) | ~525 | same |
| MTP acceptance rate | 95–97% | Consistently high |

#### Optimal llama-server flags (27B)

```bash
llama-server \
  --model Qwen3.6-27B-Q4_K_M.gguf \
  --n-gpu-layers 999 \
  --ctx-size 204800 \
  --parallel 1 \             # MTP requires single sequence
  --flash-attn on \          # required with large -b
  -b 16384 \                 # flash-attn REQUIRES large batch
  -ub 2048 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  --spec-type draft-mtp \    # built-in MTP heads
  --spec-draft-n-max 3       # draft 3 tokens per step
```

> ⚠️ **Critical pairing**: `--flash-attn on` MUST be used with `-b 16384`. Without the large batch, flash-attn drops pp from 525 → 147. Without flash-attn but with large batch, pp also drops to ~133. Only the combination works.

---

### 2️⃣ Qwen3.6-35B-A3B Q4_K — MoE Model

> **Optimization path: RADV_DEBUG=nocompute + latest llama.cpp** — MoE's sparse activation (~6.5B/token) means MTP is unnecessary. The bottleneck is kernel dispatch overhead on RDNA4, solved by `RADV_DEBUG=nocompute`.

`RADV_DEBUG=nocompute` | `KHR_cooperative_matrix` | `flash-attn on` | No MTP

#### llama-bench results (build 9870)

| Test | t/s | Notes |
|---|---|---|
| **tg128** | **164.6 ± 3.1** | **Fastest recorded R9700 35B result** |
| tg512 | 164.6 ± 3.1 | Stable across batch sizes |
| tg2048 | 165.0 ± 0.2 | Decode speed virtually unchanged |
| pp32 | 521.6 ± 38.7 | Short prefill |
| pp512 | 2901.2 ± 97.8 | Medium prefill |

#### Real server benchmark (OpenAI-compatible API)

| Run | Predicted t/s | Tokens |
|---|---|---|
| Run 1 | 135.4 | 36 |
| Run 2 | 130.8 | 36 |
| Run 3 | 137.9 | 36 |
| **Average** | **~138** | |

#### Optimization Timeline (35B MoE)

| Stage | tg (t/s) | What changed |
|---|---|---|
| Initial (first report) | ~93 | Default llama.cpp settings |
| Master branch update | ~105 | Updated to latest llama.cpp |
| `RADV_DEBUG=nocompute` | ~127 | Disabled compute queue for RDNA4 |
| `KHR_cooperative_matrix` support | **~138** | Official deployment speed (API) |
| llama-bench peak | **~165** | Benchmark peak with latest build |

> From ~93 to ~165 t/s — **~77% improvement** through software optimizations alone.

#### Optimal llama-server flags (35B MoE)

```bash
llama-server \
  --model Qwen3.6-35B-A3B-Q4_K.gguf \
  --n-gpu-layers 999 \
  --ctx-size 32768 \
  --flash-attn on \
  -b 4096 \
  -ub 512 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0
```

> For 35B MoE, `-b 4096 -ub 512` is optimal. MTP (`--spec-type draft-mtp`) regresses performance to ~105 t/s and is **not recommended** for MoE.

---

### 3️⃣ Qwen3-30B-A3B Q4_K_M — MoE Model (Community Data)

From [llama.cpp discussion #19890](https://github.com/ggml-org/llama.cpp/discussions/19890) benchmarks on the same hardware:

| Test | t/s | Notes |
|---|---|---|
| **tg128** | **183.5 ± 1.0** | ~86% bandwidth utilization |
| pp512 | 3032.6 ± 23.5 | |
| pp1024 | 3009.0 ± 25.2 | |

---

## Benchmark Reproduction / 本地重现

### llama-bench

```bash
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DGGML_CPU=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target llama-bench

# 35B MoE benchmark
RADV_DEBUG=nocompute GGML_VK_VISIBLE_DEVICES=0 \
  ./build/bin/llama-bench \
    -m /path/to/35B-moe.gguf \
    -n 512 -p 32 -ngl 999 -fa 1 -b 4096 -ub 512 -r 3

# 27B dense benchmark
RADV_DEBUG=nocompute GGML_VK_VISIBLE_DEVICES=0 \
  ./build/bin/llama-bench \
    -m /path/to/27B.gguf \
    -n 512 -p 32 -ngl 999 -fa 0 -b 16384 -ub 2048 -r 3
```

### curl API test (35B)

```bash
curl http://localhost:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"prompt": "test", "max_tokens": 128, "temperature": 0}'
```

Check the `usage.time_per_output_token_ms` / `predicted_per_second` fields in the response.

---

## ✅ Optimizations That Work / 有效的优化项

### Must-have for all models: `RADV_DEBUG=nocompute` & latest llama.cpp

**Single most impactful setting for RDNA4 gfx1201 Vulkan.** Disables compute queue — routes all work through graphics queue, avoiding a performance regression on RADV.

```yaml
environment:
  - GGML_VK_VISIBLE_DEVICES=0
  - RADV_DEBUG=nocompute
```

Without this: ~120 t/s → With this: **~138 t/s** (+15%). Also pair with the **latest llama.cpp master** for `KHR_cooperative_matrix` support — older builds without it benchmark ~117-120 t/s vs **~165 t/s**.

### ✅ For 27B Dense: MTP Speculative Decoding

| Setting | tg Speedup |
|---|---|
| No MTP (baseline) | ~20 t/s |
| **MTP (`--spec-type draft-mtp`, `--spec-draft-n-max 3`)** | **~42 t/s (2×)** |
| Required pairing | `-b 16384 -ub 2048`, `--parallel 1`, `--flash-attn on` |

### ✅ For 35B MoE: Latest llama.cpp + RADV_DEBUG=nocompute

| Setting | tg Speedup |
|---|---|
| Old build, no RADV_DEBUG (baseline) | ~117-120 t/s |
| Latest build + RADV_DEBUG | **~138 t/s (+15-20%)** |
| llama-bench peak | **~165 t/s** |
| MTP | **Regresses** (-24%) — do not use |

### System-level

```bash
# PCIe ASPM performance mode — +~10% decode
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy

# GPU power to high — stable clock speed
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
```

Resets on reboot. See [`scripts/system-optimize.sh`](scripts/system-optimize.sh) for a persistent setup.

---

## ❌ Optimizations That Don't Work / 无效或负优化项

| Optimization | 27B (dense) | 35B (MoE) | Reason |
|---|---|---|---|
| **MTP for MoE** | N/A | tg **-24%** (138→105) | MoE MTP head adds overhead; acceptance rate too low |
| AMDVLK driver | pp degrades | pp degrades | Prefill drops significantly |
| ROCm backend (HIP) | Slower | Slower | RDNA4 RADV Vulkan ~20% faster than ROCm HIP |
| Turboquant (turbo2/3/4) | Slower | Slower | CPU decompression bottleneck, GPU util ~30% |
| `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` | No effect | No effect | Already covered by `RADV_DEBUG=nocompute` |
| Dual GPU | tg **-25%** | tg **-25%** | PCIe split hurts decode more than it helps |

---

## Docker Setup / Docker 部署

### Build the image

```bash
# Clone latest llama.cpp
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

# Configure with Vulkan + CPU
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

### Docker Compose

See [`docker-compose.yml`](docker-compose.yml) for two configs:
- `llama-35b` — MoE model, no MTP, `-b 4096 -ub 512`
- `llama-27b` — Dense model, MTP enabled, `-b 16384 -ub 2048`

---

## Optimization Impact Summary / 优化效果汇总

### 27B Dense Model

| Optimization | tg | pp | Notes |
|---|---|---|---|
| **MTP spec decoding** | **+100%** | — | Biggest single gain for dense models |
| PCIe ASPM performance | +10% | +10% | Free, system-level |
| GPU power high | stabilizes | stabilizes | Prevents throttle |
| `--flash-attn on` + `-b 16384` | — | significant | Must use together |

### 35B MoE Model

| Optimization | tg | pp | Notes |
|---|---|---|---|
| **Latest llama.cpp master** | **+40%** | +15% | `KHR_cooperative_matrix` support |
| **`RADV_DEBUG=nocompute`** | **+15%** | Minor | RDNA4 gfx1201 must-have |
| PCIe ASPM performance | +10% | +10% | Free, system-level |
| GPU power high | stabilizes | stabilizes | Prevents throttle |
| `--flash-attn on` | negligible | significant | Standard recommendation |
| MTP | **-24%** | N/A | Only for dense models |

---

## References / 参考

- [llama.cpp Discussion #19890 — R9700 Performance Study](https://github.com/ggml-org/llama.cpp/discussions/19890)
- [llama.cpp RDNA4 Experiments Discussion #21043](https://github.com/ggml-org/llama.cpp/discussions/21043)
- [llama.cpp Vulkan Backend](https://github.com/ggml-org/llama.cpp)
- [RADV Mesa Driver](https://docs.mesa3d.org/drivers/radv.html)
- [AMD Radeon AI PRO R9700 Specs](https://www.amd.com/en/products/graphics/workstations/radeon-ai-pro/r9700.html)
