#!/bin/bash
set -euo pipefail

# boot_present_with_cleanup.sh - Boot-time wrapper that runs cleanup before presenting USB
# This script is called by present_usb_on_boot.service
# It checks if cleanup is needed, runs it if enabled, then calls present_usb.sh

# ===== BOOT PERFORMANCE TIMING =====
BOOT_START_MS=$(date +%s%3N)
log_timing() {
    local checkpoint="$1"
    local now_ms=$(date +%s%3N)
    local elapsed=$((now_ms - BOOT_START_MS))
    echo "[BOOT TIMING] +${elapsed}ms: $checkpoint"
}
# ====================================

log_timing "脚本已启动"

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
log_timing "脚本目录已解析"

source "$SCRIPT_DIR/config.sh"
log_timing "配置已加载"

CLEANUP_CONFIG="$GADGET_DIR/cleanup_config.json"
CLEANUP_SCRIPT="$GADGET_DIR/scripts/run_boot_cleanup.py"
LOG_FILE="$GADGET_DIR/boot_cleanup.log"

echo "===== 带可选清理的启动时 USB 挂载 ====="
echo "$(date)"
log_timing "变量已初始化"

# Function to check if any folder has cleanup enabled
needs_cleanup() {
    log_timing "检查清理配置"
    if [ ! -f "$CLEANUP_CONFIG" ]; then
        echo "未找到清理配置文件，跳过清理"
        log_timing "未找到清理配置"
        return 1
    fi

    # Check if any folder has "enabled": true
    if grep -q '"enabled": true' "$CLEANUP_CONFIG" 2>/dev/null; then
        echo "至少有一个文件夹启用了清理功能"
        log_timing "检测到已启用清理"
        return 0
    else
        echo "没有文件夹启用清理功能，跳过清理"
        log_timing "清理未启用"
        return 1
    fi
}

# Function to run cleanup with minimal filesystem setup
run_cleanup() {
    log_timing "开始清理流程"
    echo "正在挂载 USB 前运行自动清理..."

    # Mount partitions read-write for cleanup
    log_timing "设置循环设备用于清理"
    echo "正在以读写模式挂载分区以进行清理..."

    # Note: Images are single-partition filesystems, not partitioned disks
    # So we mount the loop device directly, not loop devicep1
    LOOP1=$(sudo losetup --find --show "$IMG_CAM")
    LOOP2=$(sudo losetup --find --show "$IMG_LIGHTSHOW")

    # Define mount points
    MNT_PART1="$MNT_DIR/part1"
    MNT_PART2="$MNT_DIR/part2"

    # Create mount points if needed
    sudo mkdir -p "$MNT_PART1" "$MNT_PART2"

    # Get filesystem types
    FS_TYPE1=$(sudo blkid -o value -s TYPE "$LOOP1" 2>/dev/null || echo "unknown")
    FS_TYPE2=$(sudo blkid -o value -s TYPE "$LOOP2" 2>/dev/null || echo "unknown")

    # Mount partition 1 (TeslaCam)
    if [ "$FS_TYPE1" = "exfat" ]; then
        sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o rw,uid=1000,gid=1000,umask=000 "$LOOP1" "$MNT_PART1"
    else
        sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o rw,uid=1000,gid=1000,umask=000 "$LOOP1" "$MNT_PART1"
    fi

    # Mount partition 2 (Lightshows/Chimes)
    if [ "$FS_TYPE2" = "exfat" ]; then
        sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o rw,uid=1000,gid=1000,umask=000 "$LOOP2" "$MNT_PART2"
    else
        sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o rw,uid=1000,gid=1000,umask=000 "$LOOP2" "$MNT_PART2"
    fi

    log_timing "分区已挂载，启动清理脚本"
    echo "分区已挂载，正在运行清理脚本..."

    # Run cleanup script
    /usr/bin/python3 "$CLEANUP_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    CLEANUP_RESULT=${PIPESTATUS[0]}

    # Flush writes
    sync
    sleep 1

    # Unmount partitions
    log_timing "清理脚本完成，正在卸载"
    echo "清理完成，正在卸载分区..."
    sudo nsenter --mount=/proc/1/ns/mnt umount "$MNT_PART1" || true
    sudo nsenter --mount=/proc/1/ns/mnt umount "$MNT_PART2" || true

    # Detach loops
    sudo losetup -d "$LOOP1" || true
    sudo losetup -d "$LOOP2" || true

    log_timing "清理卸载完成（代码=$CLEANUP_RESULT）"
    if [ $CLEANUP_RESULT -eq 0 ]; then
        echo "清理成功完成"
    else
        echo "警告：清理脚本返回错误代码 $CLEANUP_RESULT"
    fi

    return $CLEANUP_RESULT
}

# Function to select random chime if random mode is enabled
select_random_chime() {
    log_timing "检查随机提示音模式"
    echo "正在检查随机提示音模式是否已启用..."

    RANDOM_CHIME_SCRIPT="$GADGET_DIR/scripts/select_random_chime.py"

    if [ ! -f "$RANDOM_CHIME_SCRIPT" ]; then
        echo "未找到随机提示音脚本，跳过"
        return 0
    fi

    # Mount part2 read-write so we can set the chime
    echo "正在挂载 part2 以选择随机提示音..."
    LOOP2=$(sudo losetup --find --show "$IMG_LIGHTSHOW")
    MNT_PART2="$MNT_DIR/part2"
    sudo mkdir -p "$MNT_PART2"

    # Get filesystem type
    FS_TYPE2=$(sudo blkid -o value -s TYPE "$LOOP2" 2>/dev/null || echo "unknown")

    # Mount partition 2 (Lightshows/Chimes)
    if [ "$FS_TYPE2" = "exfat" ]; then
        sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o rw,uid=1000,gid=1000,umask=000 "$LOOP2" "$MNT_PART2"
    else
        sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o rw,uid=1000,gid=1000,umask=000 "$LOOP2" "$MNT_PART2"
    fi

    # Run random chime selector
    /usr/bin/python3 "$RANDOM_CHIME_SCRIPT"
    RESULT=$?

    if [ $RESULT -eq 0 ]; then
        echo "随机提示音选择成功完成"
    else
        echo "随机提示音选择已跳过或失败（代码 $RESULT）"
    fi

    # Flush writes and unmount
    sync
    sleep 1
    sudo nsenter --mount=/proc/1/ns/mnt umount "$MNT_PART2" || true
    sudo losetup -d "$LOOP2" || true

    log_timing "随机提示音选择完成"
    return 0  # Don't fail boot if random chime has issues
}

# Main logic
if needs_cleanup; then
    run_cleanup || echo "清理遇到错误，但继续执行 USB 挂载..."
else
    log_timing "跳过清理（未启用）"
    echo "跳过清理（未启用）"
fi

# Select random chime if random mode is enabled
echo ""
select_random_chime

# Now run the normal present script
echo ""
log_timing "启动包装器完成，正在执行 present_usb.sh"
echo "继续执行 USB 设备挂载..."
echo "[BOOT TIMING] 启动包装器总耗时：$(($(date +%s%3N) - BOOT_START_MS))ms"
exec "$SCRIPT_DIR/present_usb.sh"
