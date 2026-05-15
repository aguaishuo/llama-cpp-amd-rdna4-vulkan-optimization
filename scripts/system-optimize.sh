#!/bin/bash
# AMD RDNA4 system-level optimizations for LLM inference
# Run with sudo / 需要 sudo 执行
# Reference: https://github.com/ggml-org/llama.cpp/discussions/21043

set -e

echo "[1/2] Setting PCIe ASPM to performance mode (+~10% decode)..."
echo performance | tee /sys/module/pcie_aspm/parameters/policy

echo "[2/2] Setting GPU power level to high (stable clocks)..."
# Try card1 first, fall back to card0
if [ -f /sys/class/drm/card1/device/power_dpm_force_performance_level ]; then
    echo high | tee /sys/class/drm/card1/device/power_dpm_force_performance_level
elif [ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]; then
    echo high | tee /sys/class/drm/card0/device/power_dpm_force_performance_level
fi

echo ""
echo "Done. Verify with:"
echo "  cat /sys/module/pcie_aspm/parameters/policy"
echo "  cat /sys/class/drm/card1/device/power_dpm_force_performance_level"
echo ""
echo "Note: These settings reset on reboot."
echo "To persist, add this script to /etc/rc.local or a systemd service."
