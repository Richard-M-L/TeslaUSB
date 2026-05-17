#!/bin/bash
set -uo pipefail

# boot_deferred_tasks.sh — Runs AFTER USB gadget is presented to Tesla.
# These tasks are deferred from boot to ensure Tesla sees the USB drive ASAP.
#
# Called by teslausb-deferred-tasks.service (After=present_usb_on_boot.service)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BOOT_START_MS=$(date +%s%3N)
log_timing() {
    local checkpoint="$1"
    local now_ms=$(date +%s%3N)
    local elapsed=$((now_ms - BOOT_START_MS))
    echo "[DEFERRED TASKS] +${elapsed}ms: $checkpoint"
}

log_timing "正在启动延迟启动任务"

# Load configuration
source "$SCRIPT_DIR/config.sh"
log_timing "配置已加载"

CLEANUP_CONFIG="$GADGET_DIR/cleanup_config.json"
CLEANUP_SCRIPT="$GADGET_DIR/scripts/run_boot_cleanup.py"
LOG_FILE="$GADGET_DIR/boot_cleanup.log"

# ============================================================================
# Task 1: Auto-cleanup (if enabled)
# ============================================================================
needs_cleanup() {
    if [ ! -f "$CLEANUP_CONFIG" ]; then
        return 1
    fi
    if grep -q '"enabled": true' "$CLEANUP_CONFIG" 2>/dev/null; then
        return 0
    fi
    return 1
}

if needs_cleanup; then
    log_timing "正在运行自动清理（必要时通过 quick_edit）..."
    # Cleanup uses the web app's cleanup service which handles mount operations
    /usr/bin/python3 "$CLEANUP_SCRIPT" 2>&1 | tee -a "$LOG_FILE" || true
    log_timing "清理完成"
else
    log_timing "清理未启用，跳过"
fi

# ============================================================================
# Task 2: Random chime selection (if enabled)
# ============================================================================
RANDOM_CHIME_SCRIPT="$GADGET_DIR/scripts/select_random_chime.py"

if [ -f "$RANDOM_CHIME_SCRIPT" ]; then
    log_timing "正在检查随机提示音模式..."
    # select_random_chime.py handles quick_edit internally if needed
    /usr/bin/python3 "$RANDOM_CHIME_SCRIPT" || true
    log_timing "随机提示音检查完成"
fi

log_timing "所有延迟任务完成（总计：$(($(date +%s%3N) - BOOT_START_MS))ms）"
