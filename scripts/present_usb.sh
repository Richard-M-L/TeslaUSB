#!/bin/bash
set -euo pipefail

# present_usb.sh - Present USB gadget with dual-LUN configuration
# This script unmounts local mounts, presents the USB gadget with optimized read-only settings on LUN 1

# Performance tracking
SCRIPT_START=$(date +%s%3N)
log_timing() {
  local label="$1"
  local now=$(date +%s%3N)
  local elapsed=$((now - SCRIPT_START))
  echo "[TIMING] ${label}: ${elapsed}ms ($(date '+%H:%M:%S.%3N'))"
}

# Smart wait with verification - replaces fixed sleeps for safety with speed
# Usage: wait_until <check_command> <max_seconds> <description>
wait_until() {
  local check_cmd="$1"
  local max_wait="$2"
  local desc="${3:-operation}"
  local elapsed=0
  local interval=0.1

  while ! eval "$check_cmd" 2>/dev/null; do
    sleep $interval
    elapsed=$(echo "$elapsed + $interval" | bc)
    if (( $(echo "$elapsed >= $max_wait" | bc -l) )); then
      echo "  警告：$desc 未在 ${max_wait}秒 内完成"
      return 1
    fi
  done
  return 0
}

# Create a fresh loop device for an image file
# After clearing any previous state, we create fresh loop devices.
# Usage: LOOP_DEV=$(create_loop "/path/to/image.img")
create_loop() {
  local img="$1"
  sudo losetup --show -f "$img"
}

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
log_timing "脚本启动"
source "$SCRIPT_DIR/config.sh"
log_timing "配置已加载"

MUSIC_ENABLED_LC="$(printf '%s' "${MUSIC_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"
MUSIC_ENABLED_BOOL=0
[ "$MUSIC_ENABLED_LC" = "true" ] && MUSIC_ENABLED_BOOL=1

# Check for active file operations before proceeding
LOCK_FILE="$GADGET_DIR/.quick_edit_part2.lock"
LOCK_TIMEOUT=30
LOCK_CHECK_START=$(date +%s)

if [ -f "$LOCK_FILE" ]; then
  echo "⚠️  检测到文件操作正在进行（发现锁文件）"
  echo "等待最多 ${LOCK_TIMEOUT}秒 等待操作完成..."

  while [ -f "$LOCK_FILE" ]; do
    LOCK_AGE=$(($(date +%s) - LOCK_CHECK_START))

    if [ $LOCK_AGE -ge $LOCK_TIMEOUT ]; then
      # Check if lock is stale (older than 2 minutes)
      if [ -f "$LOCK_FILE" ]; then
        LOCK_FILE_AGE=$(($(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)))
        if [ $LOCK_FILE_AGE -gt 120 ]; then
          echo "⚠️  正在移除过期的锁文件（已存在 ${LOCK_FILE_AGE}秒）"
          rm -f "$LOCK_FILE"
          break
        fi
      fi

      echo "❌ 错误：无法切换到展示模式 - 文件操作仍在进行中" >&2
      echo "请等待当前上传/下载/调度操作完成" >&2
      exit 1
    fi

    sleep 1
  done

  echo "✓ 文件操作已完成，继续执行模式切换"
fi

log_timing "锁检查完成"

# Boot mode detection: skip Samba/unmount/loop cleanup when called at boot
# (nothing is mounted yet — saves ~2-3 seconds)
BOOT_MODE=0
if [ "${1:-}" = "--boot" ]; then
  BOOT_MODE=1
  echo "启动模式：跳过 Samba/卸载/循环设备清理（尚未挂载任何内容）"
  log_timing "启动模式 — 跳过清理"
fi

echo "正在切换到 USB 设备展示模式..."

if [ $BOOT_MODE -eq 0 ]; then
  # Ask Samba to drop any open handles before shutting it down
  echo "正在关闭 Samba 共享..."
  sudo smbcontrol all close-share gadget_part1 2>/dev/null || true
  sudo smbcontrol all close-share gadget_part2 2>/dev/null || true

# Stop Samba so nothing can reopen the image while we transition
  echo "正在停止 Samba 服务..."
  sudo systemctl stop smbd || true
  sudo systemctl stop nmbd || true

  # Force all buffered data to disk before unmounting
  echo "正在将缓冲数据刷入磁盘..."
  sync
  # Brief pause to ensure filesystem metadata is stable (reduced from 1s)
  sleep 0.3
fi # end BOOT_MODE check

# Helper to unmount even if Samba clients are still attached
unmount_with_retry() {
  local target="$1"
  local attempt
  # Check if mounted in host namespace
  if ! sudo nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "$target" 2>/dev/null && ! mountpoint -q "$target" 2>/dev/null; then
    return 0
  fi

  for attempt in 1 2 3; do
    # Unmount in host namespace to ensure it's visible system-wide
    if sudo nsenter --mount=/proc/1/ns/mnt -- umount "$target" 2>/dev/null || sudo umount "$target" 2>/dev/null; then
      echo "  已卸载 $target"
      return 0
    fi
    echo "  $target 忙（尝试 $attempt）。正在终止剩余客户端..."
    sudo fuser -km "$target" 2>/dev/null || true
    sleep 1
  done

  echo "  无法干净地卸载 $target；正在强制延迟卸载..."
  sudo nsenter --mount=/proc/1/ns/mnt -- umount -lf "$target" 2>/dev/null || sudo umount -lf "$target" 2>/dev/null || true
  sleep 1

  # Check again in host namespace
  if sudo nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "$target" 2>/dev/null || mountpoint -q "$target" 2>/dev/null; then
    echo "  错误：强制卸载后 $target 仍处于挂载状态。" >&2
    return 1
  fi

  echo "  延迟卸载已成功完成：$target"
  return 0
}

# Unmount drives if mounted (skip at boot — nothing is mounted)
if [ $BOOT_MODE -eq 0 ]; then
log_timing "开始卸载序列"
echo "正在卸载驱动器..."
UNMOUNT_TARGETS=("$MNT_DIR/part1" "$MNT_DIR/part2")
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  UNMOUNT_TARGETS+=("$MNT_DIR/part3")
fi
for mp in "${UNMOUNT_TARGETS[@]}"; do
  # Sync each partition before unmounting
  if mountpoint -q "$mp" 2>/dev/null; then
    echo "  正在同步 $mp..."
    sudo sync -f "$mp" 2>/dev/null || sync
  fi
  if ! unmount_with_retry "$mp"; then
    echo "  中止设备展示以避免损坏。" >&2
    exit 1
  fi
done

log_timing "驱动器已卸载"

# Also unmount any existing read-only mounts from previous present mode
echo "正在卸载现有的只读挂载点..."
RO_MNT_DIR="/mnt/gadget"
RO_UNMOUNT_TARGETS=("$RO_MNT_DIR/part1-ro" "$RO_MNT_DIR/part2-ro")
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  RO_UNMOUNT_TARGETS+=("$RO_MNT_DIR/part3-ro")
fi
for mp in "${RO_UNMOUNT_TARGETS[@]}"; do
  if mountpoint -q "$mp" 2>/dev/null || sudo nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "$mp" 2>/dev/null; then
    echo "  正在卸载 $mp..."
    unmount_with_retry "$mp" || true
  fi
done

# One final sync after all unmounts
sync
log_timing "最终同步完成"

# Clean up existing loop devices for our images
# After unmounting, detach any lingering loop devices to avoid accumulation
echo "正在清理现有的循环设备..."
LOOP_IMAGES=("$IMG_CAM" "$IMG_LIGHTSHOW")
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  LOOP_IMAGES+=("$IMG_MUSIC")
fi
for img in "${LOOP_IMAGES[@]}"; do
  for loop in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do
    if [ -n "$loop" ]; then
      echo "  正在分离 $loop..."
      sudo losetup -d "$loop" 2>/dev/null || true
    fi
  done
done
# Brief pause for loop device cleanup to complete
sleep 0.2
log_timing "循环设备已清理"
fi # end BOOT_MODE unmount/cleanup skip

# ============================================================================
# Boot-time filesystem check and repair (optional, ~1 second total)
# ============================================================================
# These variables will hold loop devices for reuse later in the script
LOOP_CAM=""
LOOP_LIGHTSHOW=""
LOOP_MUSIC=""

# Skip fsck at boot — USB gadget presentation is #1 priority.
# fsck runs on edit→present transitions (non-boot mode) to catch corruption.
# At boot, the images were either: (a) freshly created, or (b) previously fsck'd.
if [ $BOOT_MODE -eq 1 ]; then
  echo "启动模式：延迟文件系统检查（USB 展示优先）"
  log_timing "文件系统检查已延迟（启动模式）"
elif [ "${BOOT_FSCK_ENABLED:-false}" = "true" ]; then
  echo "正在运行文件系统检查和修复（并行）..."

  # Create loop devices for fsck (will be reused for local mounts too)
  LOOP_CAM=$(create_loop "$IMG_CAM")
  LOOP_LIGHTSHOW=$(create_loop "$IMG_LIGHTSHOW")
  if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
    LOOP_MUSIC=$(create_loop "$IMG_MUSIC")
  fi

  # Detect filesystem types
  FS_TYPE_CAM=$(sudo blkid -o value -s TYPE "$LOOP_CAM" 2>/dev/null || echo "exfat")
  FS_TYPE_LIGHTSHOW=$(sudo blkid -o value -s TYPE "$LOOP_LIGHTSHOW" 2>/dev/null || echo "vfat")
  if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
    FS_TYPE_MUSIC=$(sudo blkid -o value -s TYPE "$LOOP_MUSIC" 2>/dev/null || echo "vfat")
  fi

  # Helper to run fsck on a single partition
  run_fsck() {
    local label="$1" fs_type="$2" loop="$3"
    if [ "$fs_type" = "exfat" ]; then
      sudo fsck.exfat -p "$loop" >/dev/null 2>&1
    else
      sudo fsck.vfat -p "$loop" >/dev/null 2>&1
    fi
    local rc=$?
    if [ $rc -eq 0 ]; then
      echo "    ✓ $label: 正常"
    else
      echo "    ⚠ $label: 已修复或存在问题 (rc=$rc)"
    fi
  }

  # Run all fsck operations in parallel for speed
  run_fsck "TeslaCam" "$FS_TYPE_CAM" "$LOOP_CAM" &
  FSCK_PID1=$!
  run_fsck "LightShow" "$FS_TYPE_LIGHTSHOW" "$LOOP_LIGHTSHOW" &
  FSCK_PID2=$!
  if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
    run_fsck "Music" "$FS_TYPE_MUSIC" "$LOOP_MUSIC" &
    FSCK_PID3=$!
  fi

  # Wait for all fsck jobs to complete
  wait $FSCK_PID1 || true
  wait $FSCK_PID2 || true
  if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
    wait $FSCK_PID3 || true
  fi

  echo "  循环设备已保留供本地挂载重用"
  log_timing "启动时文件系统检查已完成（并行）"
else
  echo "启动时文件系统检查已禁用（设置 disk_images.boot_fsck_enabled: true 以启用）"
fi

# Remove mount directories to avoid accidental access when unmounted
echo "正在移除挂载目录..."
REMOVE_TARGETS=("$MNT_DIR/part1" "$MNT_DIR/part2")
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  REMOVE_TARGETS+=("$MNT_DIR/part3")
fi
for mp in "${REMOVE_TARGETS[@]}"; do
  # Check if mounted in host namespace
  if sudo nsenter --mount=/proc/1/ns/mnt -- mountpoint -q "$mp" 2>/dev/null || mountpoint -q "$mp" 2>/dev/null; then
    echo "  跳过移除 $mp（仍处于挂载状态）" >&2
    continue
  fi
  if [ -d "$mp" ]; then
    sudo rm -rf "$mp" || true
  fi
done

# Flush any pending writes to the image files
echo "正在刷新待处理的文件系统缓冲区..."
sync

# Note: We don't need to detach existing loop devices for the gadget to work.
# The USB gadget uses the image files directly, not through loop devices.
# Loop devices are only needed for local mounting. If they exist from a previous
# session, that's fine - the gadget can still access the files.

# Path to our configfs gadget (declared up front so the boot-mode skip
# wrapper below can safely reference it under `set -u`).
CONFIGFS_GADGET="/sys/kernel/config/usb_gadget/teslausb"

# At boot, the conflicting-service stop loop, the rmmod check, and the
# configfs cleanup are all dead work — setup_usb.sh masks rpi-usb-gadget
# unconditionally, g_mass_storage is never loaded, and no prior teslausb
# gadget exists yet. Skip them unless we're not in boot mode OR an unexpected
# leftover gadget is actually present (~700ms saved per boot).
if [ "$BOOT_MODE" -eq 0 ] || [ -d "$CONFIGFS_GADGET" ]; then
  # Stop conflicting rpi-usb-gadget service if running (Pi OS Bookworm+ default)
  # This service claims the UDC for a USB Ethernet gadget, blocking our mass-storage gadget
  for svc in rpi-usb-gadget.service usb-gadget.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "正在停止冲突的服务 $svc..."
      sudo systemctl stop "$svc" 2>/dev/null || true
      sleep 0.3
    fi
  done

  # Remove legacy gadget module if present
  if lsmod | grep -q '^g_mass_storage'; then
    echo "正在移除现有的 USB 设备模块..."
    sudo rmmod g_mass_storage || true
    sleep 1
  fi

  # Remove existing gadget configuration if present
  if [ -d "$CONFIGFS_GADGET" ]; then
    echo "正在移除现有的设备配置..."

    # Unbind UDC first
    if [ -f "$CONFIGFS_GADGET/UDC" ]; then
      echo "" | sudo tee "$CONFIGFS_GADGET/UDC" > /dev/null 2>&1 || true
      # Brief settle time (reduced from 1s - unbind is synchronous)
      sleep 0.3
    fi

    # Clear LUN backing files to release kernel file references
    for lun in "$CONFIGFS_GADGET"/functions/mass_storage.usb0/lun.*; do
      if [ -f "$lun/file" ]; then
        echo "" | sudo tee "$lun/file" > /dev/null 2>&1 || true
      fi
    done
    sleep 0.1

    # Remove function links
    sudo rm -f "$CONFIGFS_GADGET"/configs/*/mass_storage.* 2>/dev/null || true

    # Remove configurations
    sudo rmdir "$CONFIGFS_GADGET"/configs/*/strings/* 2>/dev/null || true
    sudo rmdir "$CONFIGFS_GADGET"/configs/* 2>/dev/null || true

    # Remove LUNs from functions
    sudo rmdir "$CONFIGFS_GADGET"/functions/mass_storage.usb0/lun.* 2>/dev/null || true

    # Remove functions
    sudo rmdir "$CONFIGFS_GADGET"/functions/* 2>/dev/null || true

    # Remove strings
    sudo rmdir "$CONFIGFS_GADGET"/strings/* 2>/dev/null || true

    # Remove gadget
    sudo rmdir "$CONFIGFS_GADGET" 2>/dev/null || true
  fi
else
  echo "启动模式：跳过拆卸步骤（没有遗留的设备）"
fi

log_timing "设备已移除/清除"

# Mount configfs if not already mounted. Fail loud if we can't — the
# subsequent gadget setup writes into /sys/kernel/config and would otherwise
# produce confusing errors.
if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
  sudo modprobe configfs 2>/dev/null || true
  sudo modprobe libcomposite 2>/dev/null || true
  sudo mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi
if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
  echo "错误：configfs 未挂载到 /sys/kernel/config" >&2
  exit 1
fi

# Present dual-LUN gadget using configfs
echo "正在展示 USB 设备（双 LUN：TeslaCam 读写 + Lightshow 只读）..."

# Create gadget directory
sudo mkdir -p "$CONFIGFS_GADGET"
cd "$CONFIGFS_GADGET"

# Device descriptors (Tesla-compatible)
echo 0x1d6b | sudo tee idVendor > /dev/null  # Linux Foundation
echo 0x0104 | sudo tee idProduct > /dev/null # Multifunction Composite Gadget
echo 0x0100 | sudo tee bcdDevice > /dev/null # Device version 1.0
echo 0x0200 | sudo tee bcdUSB > /dev/null    # USB 2.0

# String descriptors
sudo mkdir -p strings/0x409
echo "$(cat /proc/sys/kernel/random/uuid | cut -c1-15)" | sudo tee strings/0x409/serialnumber > /dev/null
echo "TeslaUSB" | sudo tee strings/0x409/manufacturer > /dev/null
echo "Tesla Storage" | sudo tee strings/0x409/product > /dev/null

# Create configuration
sudo mkdir -p configs/c.1
sudo mkdir -p configs/c.1/strings/0x409
echo "TeslaCam + Lightshow" | sudo tee configs/c.1/strings/0x409/configuration > /dev/null
echo 500 | sudo tee configs/c.1/MaxPower > /dev/null  # 500mA

# Create mass storage function
sudo mkdir -p functions/mass_storage.usb0

# Configure LUN 0: TeslaCam (READ-WRITE)
echo 1 | sudo tee functions/mass_storage.usb0/stall > /dev/null
echo 1 | sudo tee functions/mass_storage.usb0/lun.0/removable > /dev/null
echo 0 | sudo tee functions/mass_storage.usb0/lun.0/ro > /dev/null  # Read-write for Tesla to record
echo 0 | sudo tee functions/mass_storage.usb0/lun.0/cdrom > /dev/null
echo "$IMG_CAM" | sudo tee functions/mass_storage.usb0/lun.0/file > /dev/null

# Configure LUN 1: Lightshow (READ-ONLY)
# Create LUN 1 directory explicitly
sudo mkdir -p functions/mass_storage.usb0/lun.1
echo 1 | sudo tee functions/mass_storage.usb0/lun.1/removable > /dev/null
echo 1 | sudo tee functions/mass_storage.usb0/lun.1/ro > /dev/null  # Read-only for performance!
echo 0 | sudo tee functions/mass_storage.usb0/lun.1/cdrom > /dev/null
echo "$IMG_LIGHTSHOW" | sudo tee functions/mass_storage.usb0/lun.1/file > /dev/null

# Configure LUN 2: Music (READ-ONLY to Tesla)
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  if [ ! -f "$IMG_MUSIC" ]; then
    echo "警告：在 $IMG_MUSIC 未找到音乐镜像 — 跳过 LUN 2" >&2
    MUSIC_ENABLED_BOOL=0
  else
    sudo mkdir -p functions/mass_storage.usb0/lun.2
    echo 1 | sudo tee functions/mass_storage.usb0/lun.2/removable > /dev/null
    echo 1 | sudo tee functions/mass_storage.usb0/lun.2/ro > /dev/null
    echo 0 | sudo tee functions/mass_storage.usb0/lun.2/cdrom > /dev/null
    echo "$IMG_MUSIC" | sudo tee functions/mass_storage.usb0/lun.2/file > /dev/null
  fi
fi

# Link function to configuration
sudo ln -s functions/mass_storage.usb0 configs/c.1/

# Find and enable UDC. We're now scheduled before multi-user.target, so
# /sys/class/udc may briefly be empty if dwc2's UDC node hasn't appeared yet.
# Wait up to 5 seconds (50 * 100ms) using integer math (no `bc` dependency).
UDC_DEVICE=""
for _ in $(seq 1 50); do
  UDC_DEVICE="$(ls /sys/class/udc 2>/dev/null | head -n1 || true)"
  [ -n "$UDC_DEVICE" ] && break
  sleep 0.1
done
if [ -z "$UDC_DEVICE" ]; then
  echo "错误：5 秒后未找到 UDC 设备。dwc2 模块是否已加载？" >&2
  exit 1
fi

echo "正在绑定到 UDC：$UDC_DEVICE"
echo "$UDC_DEVICE" | sudo tee UDC > /dev/null

echo "正在更新模式状态..."
echo "present" > "$STATE_FILE"
chown "$TARGET_USER:$TARGET_USER" "$STATE_FILE" 2>/dev/null || true

# Mount partitions locally in read-only mode for browsing
# NOTE: These mounts allow you to browse/read files while the gadget is presented.
# This is generally safe for read-only access, but be aware:
# - If the host (Tesla) is actively writing to TeslaCam, you may see stale cached data
# - Best used when Tesla is not actively recording (e.g., after driving)
echo "正在以只读模式本地挂载分区..."
RO_MNT_DIR="/mnt/gadget"
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  sudo mkdir -p "$RO_MNT_DIR/part1-ro" "$RO_MNT_DIR/part2-ro" "$RO_MNT_DIR/part3-ro"
else
  sudo mkdir -p "$RO_MNT_DIR/part1-ro" "$RO_MNT_DIR/part2-ro"
fi

# Get user IDs for mounting
UID_VAL=$(id -u "$TARGET_USER")
GID_VAL=$(id -g "$TARGET_USER")

# Mount TeslaCam image (part1) - reuse fsck loop device if available, otherwise create
if [ -z "$LOOP_CAM" ] || [ ! -e "$LOOP_CAM" ]; then
  LOOP_CAM=$(create_loop "$IMG_CAM")
fi

if [ -n "$LOOP_CAM" ] && [ -e "$LOOP_CAM" ]; then
  # Detect filesystem type
  FS_TYPE=$(sudo blkid -o value -s TYPE "$LOOP_CAM" 2>/dev/null || echo "vfat")

  echo "  正在挂载 ${LOOP_CAM}（TeslaCam）到 $RO_MNT_DIR/part1-ro（只读）..."

  if [ "$FS_TYPE" = "vfat" ]; then
    sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o ro,uid=$UID_VAL,gid=$GID_VAL,umask=022 "$LOOP_CAM" "$RO_MNT_DIR/part1-ro"
  elif [ "$FS_TYPE" = "exfat" ]; then
    sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o ro,uid=$UID_VAL,gid=$GID_VAL,umask=022 "$LOOP_CAM" "$RO_MNT_DIR/part1-ro"
  else
    sudo nsenter --mount=/proc/1/ns/mnt mount -o ro "$LOOP_CAM" "$RO_MNT_DIR/part1-ro"
  fi

  echo "  已成功挂载到 $RO_MNT_DIR/part1-ro"
else
  echo "  警告：无法为 TeslaCam 只读挂载附加循环设备"
fi

# Mount Lightshow image (part2) - reuse fsck loop device if available, otherwise create
if [ -z "$LOOP_LIGHTSHOW" ] || [ ! -e "$LOOP_LIGHTSHOW" ]; then
  LOOP_LIGHTSHOW=$(create_loop "$IMG_LIGHTSHOW")
fi

if [ -n "$LOOP_LIGHTSHOW" ] && [ -e "$LOOP_LIGHTSHOW" ]; then
  # Detect filesystem type
  FS_TYPE=$(sudo blkid -o value -s TYPE "$LOOP_LIGHTSHOW" 2>/dev/null || echo "vfat")

  echo "  正在挂载 ${LOOP_LIGHTSHOW}（Lightshow）到 $RO_MNT_DIR/part2-ro（只读）..."

  if [ "$FS_TYPE" = "vfat" ]; then
    sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o ro,uid=$UID_VAL,gid=$GID_VAL,umask=022 "$LOOP_LIGHTSHOW" "$RO_MNT_DIR/part2-ro"
  elif [ "$FS_TYPE" = "exfat" ]; then
    sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o ro,uid=$UID_VAL,gid=$GID_VAL,umask=022 "$LOOP_LIGHTSHOW" "$RO_MNT_DIR/part2-ro"
  else
    sudo nsenter --mount=/proc/1/ns/mnt mount -o ro "$LOOP_LIGHTSHOW" "$RO_MNT_DIR/part2-ro"
  fi

  echo "  已成功挂载到 $RO_MNT_DIR/part2-ro"
else
  echo "  警告：无法为 Lightshow 只读挂载附加循环设备"
fi

# Mount Music image (part3) when enabled - reuse fsck loop device if available, otherwise create
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  if [ -z "$LOOP_MUSIC" ] || [ ! -e "$LOOP_MUSIC" ]; then
    LOOP_MUSIC=$(create_loop "$IMG_MUSIC")
  fi

  if [ -n "$LOOP_MUSIC" ] && [ -e "$LOOP_MUSIC" ]; then
    FS_TYPE=$(sudo blkid -o value -s TYPE "$LOOP_MUSIC" 2>/dev/null || echo "vfat")

    echo "  正在挂载 ${LOOP_MUSIC}（Music）到 $RO_MNT_DIR/part3-ro（只读）..."

    if [ "$FS_TYPE" = "vfat" ]; then
      sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o ro,uid=$UID_VAL,gid=$GID_VAL,umask=022 "$LOOP_MUSIC" "$RO_MNT_DIR/part3-ro"
    elif [ "$FS_TYPE" = "exfat" ]; then
      sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o ro,uid=$UID_VAL,gid=$GID_VAL,umask=022 "$LOOP_MUSIC" "$RO_MNT_DIR/part3-ro"
    else
      sudo nsenter --mount=/proc/1/ns/mnt mount -o ro "$LOOP_MUSIC" "$RO_MNT_DIR/part3-ro"
    fi

    echo "  已成功挂载到 $RO_MNT_DIR/part3-ro"
  else
    echo "  警告：无法为 Music 只读挂载附加循环设备"
  fi
fi
log_timing "USB 设备已完全配置并挂载"

echo "USB 设备展示成功！"
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  echo "Pi 现在应显示为三个 USB 存储设备："
else
  echo "Pi 现在应显示为两个 USB 存储设备："
fi
echo "  - LUN 0: TeslaCam（读写）- Tesla 可录制行车记录仪视频"
echo "  - LUN 1: Lightshow（只读）- 为 Tesla 优化读取性能"
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  echo "  - LUN 2: Music（只读）- Tesla 音频媒体文件"
fi
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  echo "只读挂载点位于：$RO_MNT_DIR/part1-ro, $RO_MNT_DIR/part2-ro, $RO_MNT_DIR/part3-ro"
else
  echo "只读挂载点位于：$RO_MNT_DIR/part1-ro 和 $RO_MNT_DIR/part2-ro"
fi

log_timing "脚本成功完成"
echo "[PERFORMANCE] 总执行时间：$(($(date +%s%3N) - SCRIPT_START))ms"
