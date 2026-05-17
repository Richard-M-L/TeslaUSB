#!/usr/bin/env bash
# Helper script to run fsck with swap support
# Usage: fsck_with_swap.sh <device> <filesystem_type> [mode] [timeout_override]
# Modes: quick (read-only check), repair (auto-repair)
# timeout_override: Optional timeout in seconds (overrides defaults)

set -euo pipefail

DEVICE="$1"
FS_TYPE="$2"
MODE="${3:-quick}"
TIMEOUT_OVERRIDE="${4:-}"
SWAP_FILE="/var/swap/fsck.swap"
LOG_FILE="/var/log/teslausb/fsck_$(basename "$DEVICE").log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

echo "正在对 $DEVICE 执行文件系统检查（类型：$FS_TYPE，模式：$MODE）"

# Enable swap if it exists and isn't already enabled
SWAP_ENABLED=0
if [ -f "$SWAP_FILE" ]; then
  if ! swapon --show | grep -q "$SWAP_FILE"; then
    echo "正在启用交换空间以支持 fsck 操作..."
    swapon "$SWAP_FILE" 2>/dev/null || {
      echo "警告：无法启用交换空间（可能已处于活动状态）"
    }
    SWAP_ENABLED=1
  fi
fi

# Cleanup function
cleanup() {
  if [ $SWAP_ENABLED -eq 1 ]; then
    echo "正在禁用交换空间..."
    swapoff "$SWAP_FILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Run appropriate fsck based on filesystem type and mode
FSCK_STATUS=0

# Determine timeout values
# For web-initiated background checks on large filesystems:
# - Quick check: 30 minutes (1800s) - read-only, can be slow on large partitions
# - Repair: 2 hours (7200s) - may need to fix many issues
# Legacy mode (present_usb.sh compatibility): 5min quick, 10min repair
if [ -n "$TIMEOUT_OVERRIDE" ]; then
  # Custom timeout specified
  TIMEOUT="$TIMEOUT_OVERRIDE"
  echo "使用自定义超时：${TIMEOUT}秒"
elif [ "${FSCK_BACKGROUND:-0}" = "1" ]; then
  # Background mode (called from web service) - use extended timeouts
  if [ "$MODE" = "repair" ]; then
    TIMEOUT=7200  # 2 hours for repair
  else
    TIMEOUT=1800  # 30 minutes for quick check
  fi
  echo "使用后台超时：${TIMEOUT}秒"
else
  # Legacy short timeouts (for any remaining direct calls)
  if [ "$MODE" = "repair" ]; then
    TIMEOUT=600   # 10 minutes
  else
    TIMEOUT=300   # 5 minutes
  fi
  echo "使用标准超时：${TIMEOUT}秒"
fi

case "$FS_TYPE" in
  vfat)
    if [ "$MODE" = "repair" ]; then
      timeout "$TIMEOUT" fsck.vfat -a "$DEVICE" >"$LOG_FILE" 2>&1 || FSCK_STATUS=$?
    else
      timeout "$TIMEOUT" fsck.vfat -n "$DEVICE" >"$LOG_FILE" 2>&1 || FSCK_STATUS=$?
    fi
    ;;
  exfat)
    if [ "$MODE" = "repair" ]; then
      timeout "$TIMEOUT" fsck.exfat -p "$DEVICE" >"$LOG_FILE" 2>&1 || FSCK_STATUS=$?
    else
      # Quick read-only check
      timeout "$TIMEOUT" fsck.exfat -n "$DEVICE" >"$LOG_FILE" 2>&1 || FSCK_STATUS=$?
    fi
    ;;
  *)
    echo "错误：不支持的文件系统类型：$FS_TYPE" >&2
    exit 1
    ;;
esac

# Interpret fsck exit codes
# Note: Exit code meaning depends on mode:
#   - Quick mode (-n): exit 1 = errors found but not fixed (read-only)
#   - Repair mode (-a/-p): exit 1 = errors found and corrected
case $FSCK_STATUS in
  0)
    echo "✓ 文件系统检查通过 - 未发现错误"
    rm -f "$LOG_FILE"
    exit 0
    ;;
  1)
    if [ "$MODE" = "repair" ]; then
      echo "✓ 文件系统错误已成功修复"
      echo "   详情：$LOG_FILE"
      exit 1
    else
      # Quick mode: exit 1 means errors were found but not fixed (read-only check)
      echo "⚠ 检测到文件系统错误（只读检查）"
      echo "   请运行修复模式来修复这些错误"
      echo "   详情：$LOG_FILE"
      exit 4  # Map to "errors uncorrected" for quick mode
    fi
    ;;
  2)
    echo "⚠ 文件系统已修复 - 应重新启动系统"
    echo "   详情：$LOG_FILE"
    exit 2
    ;;
  4)
    echo "✗ 文件系统错误未修复"
    echo "   详情：$LOG_FILE"
    exit 4
    ;;
  8)
    echo "✗ fsck 操作出现错误"
    echo "   详情：$LOG_FILE"
    exit 8
    ;;
  124)
    echo "⚠ 文件系统检查超时"
    echo "   详情：$LOG_FILE"
    exit 124
    ;;
  *)
    echo "✗ 未知的 fsck 退出码：$FSCK_STATUS"
    echo "   详情：$LOG_FILE"
    exit $FSCK_STATUS
    ;;
esac
