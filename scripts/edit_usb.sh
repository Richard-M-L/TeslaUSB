#!/bin/bash
set -euo pipefail

# edit_usb.sh - Switch to edit mode with local mounts and Samba
# This script removes the USB gadget, mounts drives locally, and starts Samba

# Performance tracking
SCRIPT_START=$(date +%s%3N)
log_timing() {
  local label="$1"
  local now=$(date +%s%3N)
  local elapsed=$((now - SCRIPT_START))
  echo "[TIMING] ${label}: ${elapsed}ms ($(date '+%H:%M:%S.%3N'))"
}

# Smart wait: polls until condition is true or timeout (much faster than fixed sleep)
# Usage: wait_until "test -condition" 5 "description"
wait_until() {
  local check_cmd="$1"
  local max_wait="$2"
  local desc="${3:-operation}"
  local start=$(date +%s%3N)
  local deadline=$((start + max_wait * 1000))

  while ! eval "$check_cmd" 2>/dev/null; do
    local now=$(date +%s%3N)
    if [ $now -ge $deadline ]; then
      return 1
    fi
    sleep 0.05
  done
  return 0
}

# Create a fresh loop device for an image file
# After clearing gadget LUN files and unmounting, existing loop devices will have
# AUTOCLEAR set and will be automatically destroyed. We create fresh ones.
# Usage: LOOP_DEV=$(create_loop "/path/to/image.img")
create_loop() {
  local img="$1"
  sudo losetup --show -f "$img"
}

log_timing "脚本启动"

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

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

      echo "❌ 错误：无法切换到编辑模式 - 文件操作仍在进行中" >&2
      echo "请等待当前上传/下载/调度操作完成" >&2
      exit 1
    fi

    sleep 1
  done

  echo "✓ 文件操作已完成，继续执行模式切换"
fi

echo "正在切换到编辑模式（本地挂载 + Samba）..."

# Get user IDs for mounting
UID_VAL=$(id -u "$TARGET_USER")
GID_VAL=$(id -g "$TARGET_USER")

safe_unmount_dir() {
  local target="$1"
  local attempt

  # Check if actually mounted in the system mount namespace
  if ! sudo nsenter --mount=/proc/1/ns/mnt mountpoint -q "$target" 2>/dev/null; then
    return 0
  fi

  # Try normal unmount in the system mount namespace
  for attempt in 1 2 3; do
    if sudo nsenter --mount=/proc/1/ns/mnt umount "$target" 2>/dev/null; then
      # Quick poll to verify unmount (much faster than fixed sleep)
      if wait_until "! sudo nsenter --mount=/proc/1/ns/mnt mountpoint -q '$target'" 1 "verify unmount"; then
        return 0
      fi
      echo "  警告：umount 成功但挂载点仍然存在（多个挂载？）"
    fi

    # Still mounted, brief pause before retry
    [ $attempt -lt 3 ] && sleep 0.2
  done

  # If still mounted, this is an error - don't continue
  echo "  错误：尝试 3 次后仍无法卸载 $target" >&2
  echo "  必须先清除此挂载点，编辑模式才能工作" >&2
  return 1
}

# Remove gadget if active (with force to prevent hanging)
# First check for configfs gadget
CONFIGFS_GADGET="/sys/kernel/config/usb_gadget/teslausb"
if [ -d "$CONFIGFS_GADGET" ]; then
  echo "正在移除 configfs USB 设备..."
  # Sync all pending writes first
  sync
  # Brief pause for filesystem stability (reduced from 1s)
  sleep 0.2

  # Unbind UDC FIRST - this disconnects the gadget from USB before touching mounts
  if [ -f "$CONFIGFS_GADGET/UDC" ]; then
    echo "  正在解除 UDC 绑定..."
    echo "" | sudo tee "$CONFIGFS_GADGET/UDC" > /dev/null 2>&1 || true
    # Brief settle time (reduced from 2s - unbind is synchronous)
    sleep 0.5
  fi

  # Clear LUN backing files BEFORE removing functions
  # This releases the kernel's file references to the image files
  echo "  正在清除 LUN 后备文件..."
  for lun in "$CONFIGFS_GADGET"/functions/mass_storage.usb0/lun.*; do
    if [ -f "$lun/file" ]; then
      echo "" | sudo tee "$lun/file" > /dev/null 2>&1 || true
    fi
  done
  sleep 0.2

  # Remove function links
  echo "  正在移除功能链接..."
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

  echo "  Configfs 设备已成功移除"
  # Brief settle time (reduced from 2s)
  sleep 0.5

  # NOW unmount read-only mounts after gadget is fully disconnected
  echo "正在卸载展示模式下的只读挂载点..."
  RO_MNT_DIR="/mnt/gadget"
  RO_UNMOUNT_TARGETS=("$RO_MNT_DIR/part1-ro" "$RO_MNT_DIR/part2-ro")
  if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
    RO_UNMOUNT_TARGETS+=("$RO_MNT_DIR/part3-ro")
  fi
  for mp in "${RO_UNMOUNT_TARGETS[@]}"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      echo "  正在卸载 $mp..."
      if ! safe_unmount_dir "$mp"; then
        echo "  错误：即使断开设备连接后仍无法卸载 $mp"
        exit 1
      fi
    fi
  done

# Check for legacy g_mass_storage module
elif lsmod | grep -q '^g_mass_storage'; then
  echo "正在移除旧版 g_mass_storage 模块..."
  # Sync all pending writes first
  sync
  sleep 1

  # Unmount any read-only mounts from present mode first
  echo "正在卸载展示模式下的只读挂载点..."
  RO_MNT_DIR="/mnt/gadget"
  LEGACY_RO_TARGETS=("$RO_MNT_DIR/part1-ro" "$RO_MNT_DIR/part2-ro")
  if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
    LEGACY_RO_TARGETS+=("$RO_MNT_DIR/part3-ro")
  fi
  for mp in "${LEGACY_RO_TARGETS[@]}"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      echo "  正在卸载 $mp..."
      if ! safe_unmount_dir "$mp"; then
        echo "  警告：无法干净地卸载 $mp"
      fi
    fi
  done

  # Try to unbind the UDC (USB Device Controller) first to cleanly disconnect
  UDC_DIR="/sys/class/udc"
  if [ -d "$UDC_DIR" ]; then
    for udc in "$UDC_DIR"/*; do
      if [ -e "$udc" ]; then
        UDC_NAME=$(basename "$udc")
        echo "  正在解除 UDC 绑定：$UDC_NAME"
        echo "" | sudo tee /sys/kernel/config/usb_gadget/*/UDC 2>/dev/null || true
      fi
    done
    sleep 1
  fi

  # Now try to remove the module
  echo "  正在移除 g_mass_storage 模块..."
  if sudo timeout 5 rmmod g_mass_storage 2>/dev/null; then
    echo "  USB 设备模块已成功移除"
  else
    echo "  警告：模块移除超时或失败。正在强制移除..."
    # Kill any processes holding the module
    sudo lsof 2>/dev/null | grep g_mass_storage | awk '{print $2}' | xargs -r sudo kill -9 2>/dev/null || true
    # Try one more time
    sudo rmmod -f g_mass_storage 2>/dev/null || true
  fi
  sleep 1
fi

# Verify all mounts are released (quick check - already unmounted above)
RO_MNT_DIR="/mnt/gadget"
VERIFY_RO_TARGETS=("$RO_MNT_DIR/part1-ro" "$RO_MNT_DIR/part2-ro")
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  VERIFY_RO_TARGETS+=("$RO_MNT_DIR/part3-ro")
fi
for mp in "${VERIFY_RO_TARGETS[@]}"; do
  if sudo nsenter --mount=/proc/1/ns/mnt mountpoint -q "$mp" 2>/dev/null; then
    echo "  正在清除剩余的挂载点：$mp"
    safe_unmount_dir "$mp" || true
  fi
done
log_timing "挂载点已释放"

# Detach all existing loop devices for our images
# After clearing LUN files and unmounting, loop devices may still exist
# We must detach them before creating fresh ones to avoid accumulation
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
sleep 0.3
log_timing "循环设备已清理"

# Prepare mount points
echo "正在准备挂载点..."
sudo mkdir -p "$MNT_DIR/part1" "$MNT_DIR/part2"
sudo chown "$TARGET_USER:$TARGET_USER" "$MNT_DIR/part1" "$MNT_DIR/part2"

# Ensure previous mounts are cleared before setting up new loop devices
# This prevents remounting while drives are still in use
PART_RANGE=(1 2)
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  PART_RANGE+=(3)
fi

for PART_NUM in "${PART_RANGE[@]}"; do
  MP="$MNT_DIR/part${PART_NUM}"
  if mountpoint -q "$MP" 2>/dev/null; then
    echo "正在卸载 $MP 上的现有挂载"
    if ! safe_unmount_dir "$MP"; then
      echo "错误：无法清除 $MP 上的现有挂载" >&2
      exit 1
    fi
  fi
done

# Ensure all pending operations complete before setting up loop devices
sync
# Brief pause for stability (reduced from 1s)
sleep 0.2

# Setup loop device for TeslaCam image (part1)
echo "正在为 TeslaCam 设置循环设备..."
LOOP_CAM=$(create_loop "$IMG_CAM")
if [ -z "$LOOP_CAM" ]; then
  echo "错误：无法获取/创建 $IMG_CAM 的循环设备"
  exit 1
fi
echo "TeslaCam 使用的循环设备：$LOOP_CAM"

# Verify the loop device is actually attached to our image
VERIFY=$(sudo losetup -l | grep "$LOOP_CAM" | grep "$IMG_CAM" || true)
if [ -z "$VERIFY" ]; then
  echo "错误：循环设备 $LOOP_CAM 未连接到 $IMG_CAM"
  sudo losetup -d "$LOOP_CAM" 2>/dev/null || true
  exit 1
fi
echo "已验证：$LOOP_CAM 已连接到 $IMG_CAM"

# Setup loop device for Lightshow image (part2)
echo "正在为 Lightshow 设置循环设备..."
LOOP_LIGHTSHOW=$(create_loop "$IMG_LIGHTSHOW")
if [ -z "$LOOP_LIGHTSHOW" ]; then
  echo "错误：无法获取/创建 $IMG_LIGHTSHOW 的循环设备"
  sudo losetup -d "$LOOP_CAM" 2>/dev/null || true
  exit 1
fi
echo "Lightshow 使用的循环设备：$LOOP_LIGHTSHOW"

# Verify the loop device is actually attached to our image
VERIFY=$(sudo losetup -l | grep "$LOOP_LIGHTSHOW" | grep "$IMG_LIGHTSHOW" || true)
if [ -z "$VERIFY" ]; then
  echo "错误：循环设备 $LOOP_LIGHTSHOW 未连接到 $IMG_LIGHTSHOW"
  sudo losetup -d "$LOOP_CAM" 2>/dev/null || true
  sudo losetup -d "$LOOP_LIGHTSHOW" 2>/dev/null || true
  exit 1
fi
echo "已验证：$LOOP_LIGHTSHOW 已连接到 $IMG_LIGHTSHOW"

if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  if [ ! -f "$IMG_MUSIC" ]; then
    echo "警告：在 $IMG_MUSIC 未找到音乐镜像 — 跳过音乐分区" >&2
    MUSIC_ENABLED_BOOL=0
  else
    echo "正在为 Music 设置循环设备..."
    LOOP_MUSIC=$(create_loop "$IMG_MUSIC")
  if [ -z "$LOOP_MUSIC" ]; then
    echo "错误：无法获取/创建 $IMG_MUSIC 的循环设备"
    sudo losetup -d "$LOOP_CAM" 2>/dev/null || true
    sudo losetup -d "$LOOP_LIGHTSHOW" 2>/dev/null || true
    exit 1
  fi
  echo "Music 使用的循环设备：$LOOP_MUSIC"

  VERIFY=$(sudo losetup -l | grep "$LOOP_MUSIC" | grep "$IMG_MUSIC" || true)
  if [ -z "$VERIFY" ]; then
    echo "错误：循环设备 $LOOP_MUSIC 未连接到 $IMG_MUSIC"
    sudo losetup -d "$LOOP_CAM" 2>/dev/null || true
    sudo losetup -d "$LOOP_LIGHTSHOW" 2>/dev/null || true
    sudo losetup -d "$LOOP_MUSIC" 2>/dev/null || true
    exit 1
  fi
  echo "已验证：$LOOP_MUSIC 已连接到 $IMG_MUSIC"
  fi
fi

sleep 0.5

# Trap to log on failure but NOT detach loop devices (they may be reused/shared)
log_failure_on_exit() {
  local exit_code=$?
  if [ $exit_code -ne 0 ]; then
    echo "脚本失败，退出代码 $exit_code"
    echo "循环设备已保留用于调试："
    sudo losetup -l | head -5
  fi
}
trap log_failure_on_exit EXIT

# Filesystem checks removed from mode switching for faster operation
# Use the web interface Analytics page to run manual filesystem checks

# Mount drives
echo "正在挂载驱动器..."

# Ensure mount points exist (present mode may remove them)
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  sudo mkdir -p "$MNT_DIR/part1" "$MNT_DIR/part2" "$MNT_DIR/part3"
else
  sudo mkdir -p "$MNT_DIR/part1" "$MNT_DIR/part2"
fi
sudo chown "$TARGET_USER:$TARGET_USER" "$MNT_DIR/part1" "$MNT_DIR/part2" 2>/dev/null || true
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  sudo chown "$TARGET_USER:$TARGET_USER" "$MNT_DIR/part3" 2>/dev/null || true
fi

# Mount TeslaCam drive (part1) in system mount namespace
MP="$MNT_DIR/part1"
FS_TYPE=$(sudo blkid -o value -s TYPE "$LOOP_CAM" 2>/dev/null || echo "unknown")
echo "  正在挂载 $LOOP_CAM 到 $MP..."

if [ "$FS_TYPE" = "exfat" ]; then
  sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o rw,uid=$UID_VAL,gid=$GID_VAL,umask=000 "$LOOP_CAM" "$MP"
elif [ "$FS_TYPE" = "vfat" ]; then
  sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o rw,uid=$UID_VAL,gid=$GID_VAL,umask=000 "$LOOP_CAM" "$MP"
else
  echo "  警告：未知的文件系统类型 '$FS_TYPE'，尝试通用挂载"
  sudo nsenter --mount=/proc/1/ns/mnt mount -o rw "$LOOP_CAM" "$MP"
fi

if ! sudo nsenter --mount=/proc/1/ns/mnt mountpoint -q "$MP"; then
  echo "错误：无法将 $LOOP_CAM 挂载到 $MP" >&2
  exit 1
fi
echo "  已挂载 $LOOP_CAM 到 $MP（文件系统：$FS_TYPE）"

# Mount Lightshow drive (part2) in system mount namespace
MP="$MNT_DIR/part2"
FS_TYPE=$(sudo blkid -o value -s TYPE "$LOOP_LIGHTSHOW" 2>/dev/null || echo "unknown")
echo "  正在挂载 $LOOP_LIGHTSHOW 到 $MP..."

if [ "$FS_TYPE" = "exfat" ]; then
  sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o rw,uid=$UID_VAL,gid=$GID_VAL,umask=000 "$LOOP_LIGHTSHOW" "$MP"
elif [ "$FS_TYPE" = "vfat" ]; then
  sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o rw,uid=$UID_VAL,gid=$GID_VAL,umask=000 "$LOOP_LIGHTSHOW" "$MP"
else
  echo "  警告：未知的文件系统类型 '$FS_TYPE'，尝试通用挂载"
  sudo nsenter --mount=/proc/1/ns/mnt mount -o rw "$LOOP_LIGHTSHOW" "$MP"
fi

if ! sudo nsenter --mount=/proc/1/ns/mnt mountpoint -q "$MP"; then
  echo "错误：无法将 $LOOP_LIGHTSHOW 挂载到 $MP" >&2
  exit 1
fi
echo "  已挂载 $LOOP_LIGHTSHOW 到 $MP（文件系统：$FS_TYPE）"

if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  echo "正在将音乐驱动器（part3）挂载到系统挂载命名空间"
  MP="$MNT_DIR/part3"
  FS_TYPE=$(sudo blkid -o value -s TYPE "$LOOP_MUSIC" 2>/dev/null || echo "unknown")
  echo "  正在挂载 $LOOP_MUSIC 到 $MP..."

  if [ "$FS_TYPE" = "exfat" ]; then
    sudo nsenter --mount=/proc/1/ns/mnt mount -t exfat -o rw,uid=$UID_VAL,gid=$GID_VAL,umask=000 "$LOOP_MUSIC" "$MP"
  elif [ "$FS_TYPE" = "vfat" ]; then
    sudo nsenter --mount=/proc/1/ns/mnt mount -t vfat -o rw,uid=$UID_VAL,gid=$GID_VAL,umask=000 "$LOOP_MUSIC" "$MP"
  else
    echo "  警告：未知的文件系统类型 '$FS_TYPE'，尝试通用挂载"
    sudo nsenter --mount=/proc/1/ns/mnt mount -o rw "$LOOP_MUSIC" "$MP"
  fi

  if ! sudo nsenter --mount=/proc/1/ns/mnt mountpoint -q "$MP"; then
    echo "错误：无法将 $LOOP_MUSIC 挂载到 $MP" >&2
    exit 1
  fi
  echo "  已挂载 $LOOP_MUSIC 到 $MP（文件系统：$FS_TYPE）"
fi

# Refresh Samba so shares expose the freshly mounted drives
echo "正在刷新 Samba 共享..."
# Close any cached shares and reload config (faster than full restart)
sudo smbcontrol all close-share gadget_part1 2>/dev/null || true
sudo smbcontrol all close-share gadget_part2 2>/dev/null || true
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  sudo smbcontrol all close-share gadget_part3 2>/dev/null || true
fi
# If Samba is running, reload config is sufficient; otherwise start it
if systemctl is-active --quiet smbd; then
  sudo smbcontrol all reload-config 2>/dev/null || true
else
  # Cold start: smbd is now disabled at boot (see setup_usb.sh / issue #74)
  # to save ~4s of boot time, so this path runs every time the user enters
  # edit mode. Allow up to 10s for startup.
  sudo systemctl start smbd nmbd 2>/dev/null || true
  wait_until "systemctl is-active --quiet smbd" 10 "Samba 启动" || true
fi
log_timing "Samba 已刷新"
# Verify mounts are accessible
if [ -d "$MNT_DIR/part1" ]; then
  echo "  Part1 文件数：$(ls -A "$MNT_DIR/part1" 2>/dev/null | wc -l) 个"
fi
if [ -d "$MNT_DIR/part2" ]; then
  echo "  Part2 文件数：$(ls -A "$MNT_DIR/part2" 2>/dev/null | wc -l) 个"
fi
if [ $MUSIC_ENABLED_BOOL -eq 1 ] && [ -d "$MNT_DIR/part3" ]; then
  echo "  Part3 文件数：$(ls -A "$MNT_DIR/part3" 2>/dev/null | wc -l) 个"
fi

echo "正在更新模式状态..."
echo "edit" > "$STATE_FILE"
chown "$TARGET_USER:$TARGET_USER" "$STATE_FILE" 2>/dev/null || true

echo "正在确保缓冲写入已刷新..."
sync

echo "编辑模式已成功激活！"
echo "驱动器现已本地挂载，可通过 Samba 共享访问："
echo "  - 分区 1：$MNT_DIR/part1"
echo "  - 分区 2：$MNT_DIR/part2"
echo "  - Samba 共享：gadget_part1, gadget_part2"
if [ $MUSIC_ENABLED_BOOL -eq 1 ]; then
  echo "  - 分区 3：$MNT_DIR/part3"
  echo "  - Samba 共享：gadget_part3（音乐）"
fi

log_timing "脚本成功完成"
echo "[PERFORMANCE] 总执行时间：$(($(date +%s%3N) - SCRIPT_START))ms"
