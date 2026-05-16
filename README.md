# llama.cpp AMD RDNA4 Vulkan + MTP Optimization Guide

> AMD Radeon AI PRO R9700 / RX 9700 系列 — Vulkan 推理 + MTP 投机解码优化指南  
> AMD Radeon AI PRO R9700 / RX 9700 series — Vulkan inference + MTP speculative decoding

[![GPU](https://img.shields.io/badge/GPU-AMD%20RDNA4%20gfx1201-red)](https://www.amd.com/en/products/graphics/workstations/radeon-ai-pro/r9700.html)
[![Backend](https://img.shields.io/badge/Backend-Vulkan%20%2B%20MTP-blue)](https://github.com/ggml-org/llama.cpp)
[![Model](https://img.shields.io/badge/Model-Qwen3.6--27B-green)](https://huggingface.co/Qwen)

---

## Hardware / 硬件配置

| Component | Spec |
|---|---|
| GPU | AMD Radeon AI PRO R9700 — 32GB GDDR6, 256-bit bus (~576 GB/s) |
| CPU | AMD Ryzen 7 5700X |
| OS | Ubuntu 24.04 |
| Driver | RADV (Mesa 26.0.3 in Docker) |
| llama.cpp | Custom build with `draft-mtp` ([gg/spec-mtp-experiments](https://github.com/ggml-org/llama.cpp/tree/gg/spec-mtp-experiments)) |
| Model | Qwen3.6-27B-Q4_K_M |

---

## Benchmark Results / 测试结果

| Metric / 指标 | Result / 结果 |
|---|---|
| tg — no MTP / 不开MTP | ~20 tok/s |
| **tg — with MTP / 开MTP** | **44–48 tok/s (~2× speedup)** |
| pp (945 tokens) | ~470–560 tok/s |
| MTP acceptance rate / MTP接受率 | 95–97% |

> R9700 AI 虽然是专为AI设计的新卡（1531 TOPS INT4），但LLM的token生成是**内存带宽瓶颈**而非算力瓶颈。256-bit内存总线限制了自回归推理的原始速度。MTP通过每次验证接受约2个token，将有效带宽需求减半，是最有效的提速手段。
>
> The R9700 AI is marketed for AI (1531 TOPS INT4), but LLM decode is **memory-bandwidth bound**, not compute bound. The 256-bit bus limits raw decode speed. MTP compensates by accepting ~2 tokens per verification pass, effectively halving bandwidth demand per output token.

---

## ✅ Optimizations That Work / 有效的优化项

### System-level / 系统级

```bash
# PCIe ASPM performance mode — +~10% decode
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy

# GPU power to high — stable clock speed
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
```

> Note: resets on reboot. See [`scripts/system-optimize.sh`](scripts/system-optimize.sh) for a persistent setup.

### llama-server flags / 推理参数

```bash
llama-server \
  --model Qwen3.6-27B-Q4_K_M.gguf \
  --n-gpu-layers 999 \
  --ctx-size 204800 \
  --parallel 1 \           # MTP requires single sequence / MTP必须单序列
  --flash-attn on \
  -b 16384 \               # large batch for prefill boost / 大批次显著提升pp
  -ub 2048 \
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  --spec-type draft-mtp \  # built-in MTP heads / 使用模型内置MTP头
  --spec-draft-n-max 3     # draft 3 tokens per step
```

### Docker environment / Docker环境变量

```yaml
environment:
  - GGML_VK_VISIBLE_DEVICES=0
  - VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
```

> `VK_ICD_FILENAMES` 显式指定 RADV，避免系统同时加载多个 ICD（asahi/intel/nouveau 等）带来的不确定性。

See [`docker-compose.yml`](docker-compose.yml) for a complete ready-to-use example.

---

## ❌ Optimizations That Don't Work / 无效或负优化项

| Optimization / 项目 | Result / 结果 | Reason / 原因 |
|---|---|---|
| `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` | **-8% decode** | Dense模型下反而变慢，仅对MoE有效 |
| AMDVLK driver | tg +12% but pp **-75%** | prefill 从 ~560 降至 ~130 tok/s，chat场景不划算 |
| ROCm backend (HIP) | **~33 tok/s** vs Vulkan 44–48 | RDNA4上ROCm HIP kernel效率不如RADV Vulkan |
| Turboquant (turbo2/3/4) | slower than q4_0 | CPU成为反量化瓶颈，GPU利用率仅约30% |
| `rm_kq=1` source change | +0.8% (RADV) | 收益极小，需重新编译整个Docker镜像 |
| RADV debug / perf env vars | no impact | 测试了多种 RADV_PERFTEST 变量，均无效果 |
| Dual GPU | pp +36% but tg **-25%** | decode速度下降明显，单卡更优 |

---

## Optimization Impact Summary / 优化效果汇总

| Optimization | tg | pp | Notes |
|---|---|---|---|
| PCIe ASPM performance | +~10% | +~10% | Free, system-level |
| GPU power high | stabilizes | stabilizes | Prevents throttle |
| `-b 16384 -ub 2048` | negligible | **significant** | Main pp boost |
| MTP `spec-draft-n-max 3` + `parallel 1` | **~2×** | — | Biggest single gain |
| `VK_ICD_FILENAMES` | minor | minor | Deterministic driver selection |

---

## Build from Source / 从源码编译

```bash
# Clone the MTP-enabled branch
git clone --depth=1 --branch gg/spec-mtp-experiments \
    https://github.com/ggml-org/llama.cpp.git

cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target llama-server
```

See [`scripts/build-vulkan-mtp.sh`](scripts/build-vulkan-mtp.sh) for the full script.

---

## Reference / 参考

- [llama.cpp RDNA4 Experiments Discussion #21043](https://github.com/ggml-org/llama.cpp/discussions/21043)
- [llama.cpp MTP PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673)
- [gg/spec-mtp-experiments branch](https://github.com/ggml-org/llama.cpp/tree/gg/spec-mtp-experiments)
