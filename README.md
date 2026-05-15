# llama.cpp AMD RDNA4 Vulkan + MTP Optimization Guide

> **AMD Radeon AI PRO R9700 / RX 9700 series — Vulkan inference with MTP speculative decoding**  
> 针对 AMD RDNA4 显卡（R9700 AI / RX 9700系列）的 llama.cpp Vulkan 推理优化指南

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
| llama.cpp | Custom build with `draft-mtp` speculative decoding |
| Model | Qwen3.6-27B-Q4_K_M |

---

## Benchmark Results / 测试结果

### vs 7900XTX (RDNA3) — Vulkan, same model

| Metric | R9700 AI (RDNA4) | 7900XTX (RDNA3) | Ratio |
|---|---|---|---|
| Memory bandwidth | ~576 GB/s | ~960 GB/s | 60% |
| tg — no MTP | ~20 tok/s | ~29 tok/s | 69% |
| **tg — with MTP** | **44–48 tok/s** | **~81 tok/s** | ~57% |
| pp (945 tokens) | ~470–560 tok/s | ~823 tok/s | — |
| MTP acceptance rate | 95–97% | — | — |

> **Key insight:** R9700's tg/bandwidth ratio is *better* than 7900XTX (69% vs 60%) — RDNA4 is more compute-efficient per GB/s. MTP provides a consistent **~2× speedup** on both architectures.
>
> **关键发现：** R9700的 tg/带宽 效率比 7900XTX 更高（69% vs 60%），RDNA4架构每GB/s更高效。MTP在两代架构上都能稳定提供约**2倍加速**。

---

## Why R9700 is slower than 7900XTX for decode / 为什么解码比7900XTX慢

Despite being newer and marketed for AI (1531 TOPS INT4), the R9700 uses a **256-bit memory bus vs 384-bit on 7900XTX**. LLM token generation is **memory-bandwidth bound** — the AI accelerators help compute-bound tasks (training, fine-tuning) but not bandwidth-bound autoregressive inference.

MTP partially compensates: by accepting ~2 tokens per verification pass, effective bandwidth demand per output token is halved.

尽管R9700是专为AI设计的新卡（1531 TOPS INT4），但其**256-bit内存总线窄于7900XTX的384-bit**。LLM的token生成是**内存带宽瓶颈**，AI加速单元对训练/微调有效，但对自回归推理帮助有限。MTP通过每次验证接受约2个token，将有效带宽需求减半，弥补了这一劣势。

---

## Optimizations / 优化参数

All recommendations from [llama.cpp RDNA4 discussion #21043](https://github.com/ggml-org/llama.cpp/discussions/21043) confirmed working on gfx1201.

本帖所有优化均基于 [llama.cpp RDNA4讨论 #21043](https://github.com/ggml-org/llama.cpp/discussions/21043)，已在 gfx1201 实测验证。

### System-level / 系统级

```bash
# PCIe ASPM performance mode — +~10% decode / PCIe性能模式，解码提升约10%
echo performance | sudo tee /sys/module/pcie_aspm/parameters/policy

# GPU power to high — stable clock speed / GPU高性能模式，稳定时钟
echo high | sudo tee /sys/class/drm/card1/device/power_dpm_force_performance_level
```

### llama-server flags / 推理参数

```bash
llama-server \
  --model Qwen3.6-27B-Q4_K_M.gguf \
  --n-gpu-layers 999 \
  --ctx-size 204800 \
  --parallel 1 \          # MTP requires single sequence / MTP需要单序列
  --flash-attn on \
  -b 16384 \              # large batch for prefill / 大批次提升pp
  -ub 2048 \              # micro-batch size / 微批次
  --cache-type-k q4_0 \
  --cache-type-v q4_0 \
  --spec-type draft-mtp \ # or --spec-type mtp (branch dependent)
  --spec-draft-n-max 3    # draft 3 tokens per step / 每步预测3个token
```

### Docker environment / Docker环境变量

```yaml
environment:
  - GGML_VK_VISIBLE_DEVICES=0
  - VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json  # explicit RADV selection
```

> ⚠️ **Do NOT set `GGML_VK_ALLOW_GRAPHICS_QUEUE=1`** for dense models — confirmed **-8% decode** on dense.  
> ⚠️ **dense模型不要设置 `GGML_VK_ALLOW_GRAPHICS_QUEUE=1`**，实测解码下降8%。

---

## Docker Compose Example / Docker示例

```yaml
services:
  llama-server:
    image: llama-cpp-mtp:vulkan
    container_name: llama-server
    restart: unless-stopped
    ports:
      - "30001:8080"
    volumes:
      - /path/to/models:/models
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - video
    environment:
      - GGML_VK_VISIBLE_DEVICES=0
      - VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json
    command: >
      --model /models/Qwen3.6-27B-Q4_K_M.gguf
      --host 0.0.0.0
      --port 8080
      --n-gpu-layers 999
      --ctx-size 204800
      --parallel 1
      --flash-attn on
      -b 16384
      -ub 2048
      --cache-type-k q4_0
      --cache-type-v q4_0
      --spec-type draft-mtp
      --spec-draft-n-max 3
```

---

## Optimization Impact Summary / 优化效果汇总

| Optimization | tg impact | pp impact | Notes |
|---|---|---|---|
| PCIe ASPM performance | +~10% | +~10% | System-level, free |
| GPU power high | stabilizes | stabilizes | Prevents throttle |
| `-b 16384 -ub 2048` | negligible | **significant** | Main pp boost |
| `--spec-draft-n-max 3` + `--parallel 1` | **+~2×** | — | MTP core setting |
| `VK_ICD_FILENAMES` | minor | minor | Clean ICD selection |
| `GGML_VK_ALLOW_GRAPHICS_QUEUE` | **-8%** | — | Do NOT use for dense |
| `rm_kq=1` (source change) | +0.8% (RADV) | — | Not worth rebuilding |
| AMDVLK driver | +12.6% tg | **-75% pp** | Not recommended for chat |

---

## Reference / 参考

- [llama.cpp RDNA4 Experiments Discussion #21043](https://github.com/ggml-org/llama.cpp/discussions/21043)
- [llama.cpp MTP PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673)
- [gg/spec-mtp-experiments branch](https://github.com/ggml-org/llama.cpp/tree/gg/spec-mtp-experiments)
- [AMD Radeon AI PRO R9700 specs](https://www.amd.com/en/products/graphics/workstations/radeon-ai-pro/ai-9000-series/amd-radeon-ai-pro-r9700.html)
