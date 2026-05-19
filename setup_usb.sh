#!/usr/bin/env bash
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===== Early memory optimization (critical for Pi Zero/2W) =====
# Enable swap and free memory BEFORE any package installations
early_memory_optimization() {
  echo "正在准备系统内存以进行安装..."

  # Stop lightdm to free ~100MB RAM (critical for package installs)
  if systemctl is-active --quiet lightdm 2>/dev/null; then
    echo "  正在停止显示管理器以释放内存..."
    systemctl stop lightdm 2>/dev/null || true
  fi

  # Enable swap if available
  if [ -f /var/swap/fsck.swap ]; then
    swapon /var/swap/fsck.swap 2>/dev/null || true
  fi

  # Drop caches to free memory
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

  echo "  内存优化完成"
}

# Handle legacy /var/swap file (Raspberry Pi OS creates it as a file;
# we need it to be a directory for /var/swap/fsck.swap)
if [ -f "/var/swap" ] && [ ! -d "/var/swap" ]; then
  echo "  正在将旧版 /var/swap 文件移至 /var/swap.old..."
  swapoff /var/swap 2>/dev/null || true
  mv /var/swap /var/swap.old
fi

# Run early optimization before any package installs
early_memory_optimization

# If config.yaml does not exist (fresh clone / first install),
# create it from the versioned template so the user has a working
# default to edit.  Existing config.yaml is never overwritten.
CONFIG_IS_NEW=false
if [ ! -f "$SCRIPT_DIR/config.yaml" ]; then
  if [ -f "$SCRIPT_DIR/config.example.yaml" ]; then
    cp "$SCRIPT_DIR/config.example.yaml" "$SCRIPT_DIR/config.yaml"
    CONFIG_IS_NEW=true
  else
    echo "错误：未找到 config.example.yaml 模板文件"
    exit 1
  fi
fi

# Check if yq is installed (required to read config.yaml)
if ! command -v yq &> /dev/null; then
  echo "yq 未安装。正在安装 yq 和 python3-yaml..."
  apt-get update -qq
  apt-get install -y yq python3-yaml
  echo "✓ yq 和 python3-yaml 已安装"
fi

# Source the configuration file
if [ -f "$SCRIPT_DIR/scripts/config.sh" ]; then
  source "$SCRIPT_DIR/scripts/config.sh"
else
  echo "错误：未找到配置文件 $SCRIPT_DIR/scripts/config.sh"
  exit 1
fi

# Validate that required config values are set
if [ -z "$GADGET_DIR" ] || [ -z "$TARGET_USER" ] || [ -z "$IMG_CAM_NAME" ] || [ -z "$IMG_LIGHTSHOW_NAME" ]; then
  echo "错误：config.sh 中未设置必要的配置值"
  exit 1
fi

# Override TARGET_USER if running via sudo (prefer SUDO_USER)
if [ -n "${SUDO_USER-}" ]; then
  TARGET_USER="$SUDO_USER"
fi

# If config.yaml was just created from the template (or still uses defaults),
# warn the user about insecure default passwords before proceeding.
_check_default() {
  local key="$1" current="$2" default="$3"
  if [ "$current" = "$default" ]; then
    return 0  # match — still default
  fi
  return 1
}
WARN_ITEMS=""
_check_default "Samba 密码"     "${SAMBA_PASS:-}"     "tesla"          && WARN_ITEMS="$WARN_ITEMS  - Samba 密码 (network.samba_password) 仍为默认值 \"tesla\"\n"
_check_default "AP 热点密码"     "${OFFLINE_AP_PASSPHRASE:-}" "teslausb1234" && WARN_ITEMS="$WARN_ITEMS  - AP 热点密码 (offline_ap.passphrase) 仍为默认值 \"teslausb1234\"\n"
_check_default "AP 热点名称"     "${OFFLINE_AP_SSID:-}"      "TeslaUSB"    && WARN_ITEMS="$WARN_ITEMS  - AP 热点名称 (offline_ap.ssid) 仍为默认值 \"TeslaUSB\"\n"
if [ -n "$WARN_ITEMS" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  ⚠️  安 全 提 醒                                            ║"
  echo "╠══════════════════════════════════════════════════════════════╣"
  echo "║                                                            ║"
  echo "║  以下配置项仍使用模板默认值，存在安全风险：                  ║"
  echo "║                                                            ║"
  printf "%b" "$WARN_ITEMS"
  echo "║                                                            ║"
  if [ "$CONFIG_IS_NEW" = "true" ]; then
    echo "║  config.yaml 刚刚从模板创建，尚未编辑。                      ║"
  fi
  echo "║                                                            ║"
  echo "║  你可以：                                                   ║"
  echo "║  - 现在退出，编辑 config.yaml 后重新运行                    ║"
  echo "║  - 继续部署，之后通过 Web 界面修改（设置页面）              ║"
  echo "║                                                            ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  read -p "是否继续部署？（y=继续 / n=退出并编辑配置）[y/n]: " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "已取消。请编辑 config.yaml 后重新运行 sudo ./setup_usb.sh"
    exit 0
  fi
  echo "将继续使用当前配置进行部署..."
  echo ""
fi

IMG_CAM_PATH="$GADGET_DIR/$IMG_CAM_NAME"
IMG_LIGHTSHOW_PATH="$GADGET_DIR/$IMG_LIGHTSHOW_NAME"
IMG_MUSIC_PATH="$GADGET_DIR/$IMG_MUSIC_NAME"

# ===== Image Dashboard Functions =====

# Format bytes to human-readable GiB/MiB string
bytes_to_human() {
  local bytes="$1"
  local mib=$(( bytes / 1024 / 1024 ))
  if [ "$mib" -ge 1024 ]; then
    local gib_int=$(( mib / 1024 ))
    local gib_frac=$(( (mib % 1024) * 10 / 1024 ))
    echo "${gib_int}.${gib_frac} GiB"
  else
    echo "${mib} MiB"
  fi
}

show_image_dashboard() {
  local total_logical=0
  local image_lines=""

  # Collect per-image info
  for img_label_pair in "TeslaCam:$IMG_CAM_PATH" "Lightshow:$IMG_LIGHTSHOW_PATH" "Music:$IMG_MUSIC_PATH"; do
    local label="${img_label_pair%%:*}"
    local path="${img_label_pair#*:}"

    # Skip music if not required
    if [ "$label" = "Music" ] && [ "$MUSIC_REQUIRED" -eq 0 ]; then
      continue
    fi

    if [ -f "$path" ]; then
      local logical_bytes
      logical_bytes=$(stat --format=%s "$path" 2>/dev/null || echo 0)
      local fs_type
      fs_type=$(blkid -o value -s TYPE "$path" 2>/dev/null || echo "unknown")

      total_logical=$(( total_logical + logical_bytes ))
      image_lines+="$(printf "  %-10s %-10s  %s  (%s)" "$label:" "$(bytes_to_human $logical_bytes)" "$path" "$fs_type")\n"
    else
      image_lines+="$(printf "  %-10s %-10s  %s" "$label:" "缺失" "$path")\n"
    fi
  done

  # Filesystem totals
  mkdir -p "$GADGET_DIR" 2>/dev/null || true
  local fs_total_bytes fs_free_bytes os_reserve_bytes free_for_images_bytes
  fs_total_bytes=$(df -B1 --output=size "$GADGET_DIR" | tail -n 1 | tr -d ' ')
  fs_free_bytes=$(df -B1 --output=avail "$GADGET_DIR" | tail -n 1 | tr -d ' ')
  # OS reserve = total size - free space - space used by everything (including images)
  # free_for_images = fs_free (already excludes existing files) + existing image logical sizes - those logical sizes
  # Simpler: free_for_images = total - os_used - image_logical
  #   where os_used = total - free - image_logical_on_disk... but df free already accounts for real disk usage
  # Most accurate: OS reserve = total - free - total_logical (of existing images)
  #   This treats image logical size as "committed" even if sparse
  local fs_used_bytes
  fs_used_bytes=$(df -B1 --output=used "$GADGET_DIR" | tail -n 1 | tr -d ' ')
  os_reserve_bytes=$(( fs_used_bytes - total_logical ))
  # If images aren't fully allocated (sparse), os_reserve could be negative — clamp to 0
  if [ "$os_reserve_bytes" -lt 0 ]; then
    os_reserve_bytes=0
  fi
  # Add the configured safety headroom (default 5G)
  local safety_bytes=$(( 5 * 1024 * 1024 * 1024 ))
  local os_reserve_display=$(( os_reserve_bytes + safety_bytes ))
  # Archive reserve for RecentClips backup
  local archive_reserve_str="${ARCHIVE_RESERVE_SIZE:-50G}"
  local archive_reserve_bytes=0
  if [[ "$archive_reserve_str" =~ ^([0-9]+)([Gg])$ ]]; then
    archive_reserve_bytes=$(( ${BASH_REMATCH[1]} * 1024 * 1024 * 1024 ))
  fi

  free_for_images_bytes=$(( fs_total_bytes - os_reserve_display - archive_reserve_bytes - total_logical ))
  if [ "$free_for_images_bytes" -lt 0 ]; then
    free_for_images_bytes=0
  fi

  echo ""
  echo "============================================"
  echo "现有镜像概览"
  echo "============================================"
  echo ""
  printf "  总存储空间:            %s\n" "$(bytes_to_human $fs_total_bytes)"
  printf "  OS 预留:               %s  (系统 + 5 GiB 余量)\n" "$(bytes_to_human $os_reserve_display)"
  printf "  归档预留:              %s  (RecentClips 存档备份)\n" "$(bytes_to_human $archive_reserve_bytes)"
  echo "  ────────────────────────────────────────"
  printf "%b" "$image_lines"
  echo "  ────────────────────────────────────────"
  printf "  可用于新镜像的空间:    %s\n" "$(bytes_to_human $free_for_images_bytes)"
  echo ""
}

delete_all_images() {
  echo "正在删除所有现有镜像文件..."
  for img_pair in "TeslaCam:$IMG_CAM_PATH" "Lightshow:$IMG_LIGHTSHOW_PATH" "Music:$IMG_MUSIC_PATH"; do
    local label="${img_pair%%:*}"
    local path="${img_pair#*:}"
    if [ -f "$path" ]; then
      rm -f "$path"
      echo "  已删除: $path ($label)"
    fi
  done
  echo "所有镜像文件已删除。"
  echo ""
}

# ===== Check if image files already exist =====
MUSIC_ENABLED_LC="$(printf '%s' "${MUSIC_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')"
MUSIC_REQUIRED=$([ "$MUSIC_ENABLED_LC" = "true" ] && echo 1 || echo 0)

# Count existing images
EXISTING_COUNT=0
[ -f "$IMG_CAM_PATH" ] && EXISTING_COUNT=$((EXISTING_COUNT + 1))
[ -f "$IMG_LIGHTSHOW_PATH" ] && EXISTING_COUNT=$((EXISTING_COUNT + 1))
if [ $MUSIC_REQUIRED -eq 1 ] && [ -f "$IMG_MUSIC_PATH" ]; then
  EXISTING_COUNT=$((EXISTING_COUNT + 1))
fi

REQUIRED_COUNT=2
[ $MUSIC_REQUIRED -eq 1 ] && REQUIRED_COUNT=3
MISSING_COUNT=$(( REQUIRED_COUNT - EXISTING_COUNT ))

if [ "$EXISTING_COUNT" -eq 0 ]; then
  # ── Path A: Fresh install ──
  echo "未找到现有镜像文件。将创建所有必需的镜像。"
  SKIP_IMAGE_CREATION=0
  NEED_CAM_IMAGE=1
  NEED_LIGHTSHOW_IMAGE=1
  NEED_MUSIC_IMAGE=$MUSIC_REQUIRED
  echo ""
else
  # ── Path B: Upgrade (some or all images exist) ──
  show_image_dashboard

  # Determine which images are missing
  NEED_CAM_IMAGE=0
  NEED_LIGHTSHOW_IMAGE=0
  NEED_MUSIC_IMAGE=0
  [ ! -f "$IMG_CAM_PATH" ] && NEED_CAM_IMAGE=1
  [ ! -f "$IMG_LIGHTSHOW_PATH" ] && NEED_LIGHTSHOW_IMAGE=1
  [ $MUSIC_REQUIRED -eq 1 ] && [ ! -f "$IMG_MUSIC_PATH" ] && NEED_MUSIC_IMAGE=1

  # Build menu options dynamically
  echo "请选择要执行的操作："
  echo ""
  OPTION_NUM=1
  OPT_CREATE_MISSING=""
  OPT_DELETE_ALL=""
  OPT_KEEP=""

  if [ "$MISSING_COUNT" -gt 0 ]; then
    OPT_CREATE_MISSING="$OPTION_NUM"
    MISSING_NAMES=""
    [ "$NEED_CAM_IMAGE" -eq 1 ] && MISSING_NAMES="${MISSING_NAMES}TeslaCam "
    [ "$NEED_LIGHTSHOW_IMAGE" -eq 1 ] && MISSING_NAMES="${MISSING_NAMES}Lightshow "
    [ "$NEED_MUSIC_IMAGE" -eq 1 ] && MISSING_NAMES="${MISSING_NAMES}Music "
    echo "  ${OPTION_NUM}) 创建缺失镜像: ${MISSING_NAMES}(使用可用空间)"
    OPTION_NUM=$((OPTION_NUM + 1))
  fi

  OPT_DELETE_ALL="$OPTION_NUM"
  echo "  ${OPTION_NUM}) 删除所有镜像并重新配置大小"
  OPTION_NUM=$((OPTION_NUM + 1))

  OPT_KEEP="$OPTION_NUM"
  echo "  ${OPTION_NUM}) 保留现有镜像，跳过镜像配置"
  echo ""

  read -r -p "请选择一个选项 [${OPT_KEEP}]: " UPGRADE_CHOICE
  UPGRADE_CHOICE="${UPGRADE_CHOICE:-$OPT_KEEP}"

  if [ -n "$OPT_CREATE_MISSING" ] && [ "$UPGRADE_CHOICE" = "$OPT_CREATE_MISSING" ]; then
    # Option: Create only missing images
    echo ""
    echo "将仅创建缺失的镜像。"
    SKIP_IMAGE_CREATION=0

  elif [ "$UPGRADE_CHOICE" = "$OPT_DELETE_ALL" ]; then
    # Option: Delete all and reconfigure
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  警告：这将永久删除所有镜像文件及其内容。                ║"
    echo "║                                                         ║"
    echo "║  在继续之前，您可以从 TeslaUSB Web UI 下载您的锁车音效、 ║"
    echo "║  灯光秀、装饰贴纸以及其他内容。                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    read -r -p "输入 YES 确认删除: " CONFIRM_DELETE
    if [ "$CONFIRM_DELETE" != "YES" ]; then
      echo "删除未确认。正在中止。"
      exit 0
    fi
    echo ""
    delete_all_images
    SKIP_IMAGE_CREATION=0
    NEED_CAM_IMAGE=1
    NEED_LIGHTSHOW_IMAGE=1
    NEED_MUSIC_IMAGE=$MUSIC_REQUIRED

  elif [ "$UPGRADE_CHOICE" = "$OPT_KEEP" ]; then
    # Option: Keep existing, skip configuration
    echo ""
    echo "保留现有镜像。跳过大小配置和镜像创建。"
    SKIP_IMAGE_CREATION=1

  else
    echo "无效选项。正在中止。"
    exit 1
  fi
  echo ""
fi

# ===== Friendly image sizing (safe defaults; avoid filling rootfs) =====

mib_to_gib_str() {
  local mib="$1"
  local gib=$(( mib / 1024 ))
  if [ "$gib" -lt 1 ]; then
    echo "${mib}M"
  else
    echo "${gib}G"
  fi
}

round_down_gib_mib() {
  local mib="$1"
  local rounded=$(( (mib / 1024) * 1024 ))
  if [ "$rounded" -lt 512 ]; then
    rounded=512
  fi
  echo "$rounded"
}

fs_avail_bytes_for_path() {
  local path="$1"
  df -B1 --output=avail "$path" | tail -n 1 | tr -d ' '
}

size_to_bytes() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)([Mm])$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1024 * 1024 ))
  elif [[ "$s" =~ ^([0-9]+)([Gg])$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1024 * 1024 * 1024 ))
  else
    echo "无效的大小格式: $s (请使用 512M 或 5G)" >&2
    exit 2
  fi
}

# If sizes are not configured and we need to create images, suggest safe defaults based on free space
# on the filesystem that will store the image files (GADGET_DIR).
NEED_SIZE_VALIDATION=0
USABLE_MIB=0

if [ "$SKIP_IMAGE_CREATION" = "0" ] && { [ -z "${PART1_SIZE}" ] || [ -z "${PART2_SIZE}" ] || { [ $MUSIC_REQUIRED -eq 1 ] && [ -z "${PART3_SIZE}" ]; }; }; then
  # Ensure parent directory exists for df check
  mkdir -p "$GADGET_DIR" 2>/dev/null || true
  FS_AVAIL_BYTES="$(fs_avail_bytes_for_path "$GADGET_DIR")"

  # Headroom: default 5G, user-adjustable
  DEFAULT_RESERVE_STR="5G"

  if [ -z "${RESERVE_SIZE}" ]; then
    read -r -p "系统预留空间 — 留给操作系统的空闲空间（默认 ${DEFAULT_RESERVE_STR}）: " RESERVE_INPUT
    RESERVE_SIZE="${RESERVE_INPUT:-$DEFAULT_RESERVE_STR}"
  fi

  RESERVE_BYTES="$(size_to_bytes "$RESERVE_SIZE")"

  # Archive reserve: space set aside for RecentClips archival on SD card
  DEFAULT_ARCHIVE_RESERVE_STR="50G"

  if [ -z "${ARCHIVE_RESERVE_SIZE}" ]; then
    read -r -p "归档预留 — 留给 RecentClips 存档的空间（默认 ${DEFAULT_ARCHIVE_RESERVE_STR}）: " ARCHIVE_RESERVE_INPUT
    ARCHIVE_RESERVE_STR="${ARCHIVE_RESERVE_INPUT:-$DEFAULT_ARCHIVE_RESERVE_STR}"
  else
    ARCHIVE_RESERVE_STR="${ARCHIVE_RESERVE_SIZE}"
  fi
  ARCHIVE_RESERVE_BYTES="$(size_to_bytes "$ARCHIVE_RESERVE_STR")"

  TOTAL_RESERVE_BYTES=$(( RESERVE_BYTES + ARCHIVE_RESERVE_BYTES ))

  if [ "$FS_AVAIL_BYTES" -le "$TOTAL_RESERVE_BYTES" ]; then
    echo "错误：在 $GADGET_DIR 下没有足够的空闲空间来安全创建镜像文件。"
    echo "空闲空间:      $((FS_AVAIL_BYTES / 1024 / 1024)) MiB"
    echo "OS 预留:       $RESERVE_SIZE ($((RESERVE_BYTES / 1024 / 1024)) MiB)"
    echo "归档预留:      $ARCHIVE_RESERVE_STR ($((ARCHIVE_RESERVE_BYTES / 1024 / 1024)) MiB)"
    echo "请释放空间或将 GADGET_DIR 移至更大的文件系统。"
    exit 1
  fi

  USABLE_BYTES=$(( FS_AVAIL_BYTES - TOTAL_RESERVE_BYTES ))
  USABLE_MIB=$(( USABLE_BYTES / 1024 / 1024 ))

  # Default sizes: Lightshow 10G, Music 32G (if enabled), remaining to TeslaCam
  DEFAULT_P2_MIB=10240
  DEFAULT_P2_STR="10G"

  DEFAULT_P3_MIB=32768
  DEFAULT_P3_STR="32G"

  # Compute suggestions only for images being created
  SUG_P1_MIB=0
  SUG_P1_STR=""
  SUG_P2_STR=""
  SUG_P3_STR=""

  # Count how many images need creation
  IMAGES_TO_CREATE=0
  [ "$NEED_CAM_IMAGE" = "1" ] && IMAGES_TO_CREATE=$((IMAGES_TO_CREATE + 1))
  [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] && IMAGES_TO_CREATE=$((IMAGES_TO_CREATE + 1))
  [ "$NEED_MUSIC_IMAGE" = "1" ] && IMAGES_TO_CREATE=$((IMAGES_TO_CREATE + 1))

  if [ "$IMAGES_TO_CREATE" -eq 1 ]; then
    # Single missing image gets all usable space as suggestion
    SINGLE_MIB="$(round_down_gib_mib $USABLE_MIB)"
    SINGLE_STR="$(mib_to_gib_str "$SINGLE_MIB")"
    if [ "$NEED_CAM_IMAGE" = "1" ]; then
      SUG_P1_MIB="$SINGLE_MIB"; SUG_P1_STR="$SINGLE_STR"
    elif [ "$NEED_LIGHTSHOW_IMAGE" = "1" ]; then
      SUG_P2_STR="$SINGLE_STR"
    elif [ "$NEED_MUSIC_IMAGE" = "1" ]; then
      SUG_P3_STR="$SINGLE_STR"
    fi
  else
    # Multiple images: use defaults for lightshow/music, remainder to TeslaCam
    REMAINING_MIB=$USABLE_MIB
    BASELINE_MIB=0

    if [ "$NEED_LIGHTSHOW_IMAGE" = "1" ]; then
      SUG_P2_STR="$DEFAULT_P2_STR"
      REMAINING_MIB=$(( REMAINING_MIB - DEFAULT_P2_MIB ))
      BASELINE_MIB=$(( BASELINE_MIB + DEFAULT_P2_MIB ))
    fi

    if [ "$NEED_MUSIC_IMAGE" = "1" ]; then
      SUG_P3_STR="$DEFAULT_P3_STR"
      REMAINING_MIB=$(( REMAINING_MIB - DEFAULT_P3_MIB ))
      BASELINE_MIB=$(( BASELINE_MIB + DEFAULT_P3_MIB ))
    fi

    if [ "$BASELINE_MIB" -gt 0 ] && [ "$USABLE_MIB" -le "$BASELINE_MIB" ]; then
      echo ""
      echo "注意：默认大小合计 ${BASELINE_MIB} MiB 超出可用空间 ${USABLE_MIB} MiB。"
      echo "请根据提示手动指定较小的镜像大小。"
    fi

    if [ "$NEED_CAM_IMAGE" = "1" ]; then
      if [ "$REMAINING_MIB" -lt 1024 ]; then
        SUG_P1_STR="（需调小其他镜像后才有空间）"
        SUG_P1_MIB=0
      else
        SUG_P1_MIB="$(round_down_gib_mib $REMAINING_MIB)"
        SUG_P1_STR="$(mib_to_gib_str "$SUG_P1_MIB")"
      fi
    fi
  fi

  echo ""
  echo "============================================"
  echo "镜像大小设置"
  echo "============================================"
  echo "镜像将创建在：$GADGET_DIR"
  echo "文件系统空闲空间:  $((FS_AVAIL_BYTES / 1024 / 1024)) MiB"
  echo "OS 预留:             $((RESERVE_BYTES / 1024 / 1024)) MiB"
  echo "归档预留:            $((ARCHIVE_RESERVE_BYTES / 1024 / 1024)) MiB  (RecentClips 存档备份)"
  echo "可用于镜像的空间:    ${USABLE_MIB} MiB"
  echo ""
  echo "推荐大小（安全，为 Raspberry Pi OS 留有余量）："
  [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] && echo "  灯光秀 (PART2_SIZE): $SUG_P2_STR"
  [ "$NEED_MUSIC_IMAGE" = "1" ] && echo "  音乐     (PART3_SIZE): $SUG_P3_STR"
  [ "$NEED_CAM_IMAGE" = "1" ] && echo "  行车记录仪 (PART1_SIZE): $SUG_P1_STR"
  echo ""

  # Only prompt for sizes needed for missing images
  if [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] && [ -z "${PART2_SIZE}" ]; then
    read -r -p "输入灯光秀镜像大小（默认 ${SUG_P2_STR}）: " PART2_SIZE_INPUT
    PART2_SIZE="${PART2_SIZE_INPUT:-$SUG_P2_STR}"
    # Validate format immediately
    if ! size_to_bytes "$PART2_SIZE" >/dev/null 2>&1; then
      echo "错误：灯光秀镜像的大小格式无效: $PART2_SIZE"
      echo "请使用如 512M 或 5G 的格式（仅整数）"
      exit 2
    fi
  elif [ "$NEED_LIGHTSHOW_IMAGE" = "0" ]; then
    # Image exists, set dummy size to satisfy validation
    PART2_SIZE="${PART2_SIZE:-1G}"
  fi

  if [ $MUSIC_REQUIRED -eq 1 ] && [ "$NEED_MUSIC_IMAGE" = "1" ] && [ -z "${PART3_SIZE}" ]; then
    read -r -p "输入音乐镜像大小（默认 ${SUG_P3_STR}）: " PART3_SIZE_INPUT
    PART3_SIZE="${PART3_SIZE_INPUT:-$SUG_P3_STR}"
    if ! size_to_bytes "$PART3_SIZE" >/dev/null 2>&1; then
      echo "错误：音乐镜像的大小格式无效: $PART3_SIZE"
      echo "请使用如 512M 或 5G 的格式（仅整数）"
      exit 2
    fi
  elif [ $MUSIC_REQUIRED -eq 1 ] && [ "$NEED_MUSIC_IMAGE" = "0" ]; then
    PART3_SIZE="${PART3_SIZE:-1G}"
  fi

  if [ "$NEED_CAM_IMAGE" = "1" ] && [ -z "${PART1_SIZE}" ]; then
    if [ "$SUG_P1_MIB" -gt 0 ]; then
      read -r -p "输入行车记录仪镜像大小（默认 ${SUG_P1_STR}）: " PART1_SIZE_INPUT
      PART1_SIZE="${PART1_SIZE_INPUT:-$SUG_P1_STR}"
    else
      read -r -p "输入行车记录仪镜像大小（空间不足，请先调小其他镜像）: " PART1_SIZE_INPUT
      PART1_SIZE="${PART1_SIZE_INPUT}"
    fi
    if [ -z "$PART1_SIZE" ]; then
      echo "错误：必须指定行车记录仪镜像大小。"
      exit 2
    fi
    # Validate format immediately
    if ! size_to_bytes "$PART1_SIZE" >/dev/null 2>&1; then
      echo "错误：行车记录仪镜像的大小格式无效: $PART1_SIZE"
      echo "请使用如 512M 或 5G 的格式（仅整数）"
      exit 2
    fi
  elif [ "$NEED_CAM_IMAGE" = "0" ]; then
    # Image exists, set dummy size to satisfy validation
    PART1_SIZE="${PART1_SIZE:-1G}"
  fi

  echo ""
  echo "选定的大小："
  [ "$NEED_CAM_IMAGE" = "1" ] && echo "  PART1_SIZE=$PART1_SIZE" || echo "  PART1_SIZE=(已存在)"
  [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] && echo "  PART2_SIZE=$PART2_SIZE" || echo "  PART2_SIZE=(已存在)"
  if [ $MUSIC_REQUIRED -eq 1 ]; then
    [ "$NEED_MUSIC_IMAGE" = "1" ] && echo "  PART3_SIZE=$PART3_SIZE" || echo "  PART3_SIZE=(已存在)"
  fi
  echo ""

  NEED_SIZE_VALIDATION=1
fi

# Set default sizes if images already exist and sizes not configured
if [ "$SKIP_IMAGE_CREATION" = "1" ]; then
  PART1_SIZE="${PART1_SIZE:-1G}"  # Dummy value - image already exists
  PART2_SIZE="${PART2_SIZE:-1G}"  # Dummy value - image already exists
  [ $MUSIC_REQUIRED -eq 1 ] && PART3_SIZE="${PART3_SIZE:-1G}"
fi

# Validate user exists
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "未找到用户 $TARGET_USER。请创建该用户或使用其他 sudo 用户运行。"
  exit 1
fi
TARGET_UID=$(id -u "$TARGET_USER")
TARGET_GID=$(id -g "$TARGET_USER")
echo "目标用户: $TARGET_USER (uid=$TARGET_UID gid=$TARGET_GID)"

# Helper: convert size to MiB
to_mib() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]+)([Mm])$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ ^([0-9]+)([Gg])$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 1024 ))
  else
    echo "无效的大小格式: $s (请使用 2048M 或 4G)" >&2
    exit 2
  fi
}
P1_MB=$(to_mib "$PART1_SIZE")
P2_MB=$(to_mib "$PART2_SIZE")
if [ $MUSIC_REQUIRED -eq 1 ]; then
  P3_MB=$(to_mib "$PART3_SIZE")
else
  P3_MB=0
fi

# Note: We no longer need TOTAL_MB since we're creating separate images

# Validate selected sizes against usable space (if computed and images need creation)
if [ "${NEED_SIZE_VALIDATION:-0}" = "1" ] && [ "$SKIP_IMAGE_CREATION" = "0" ]; then
  # Only sum sizes for images actually being created (exclude dummy values for existing images)
  TOTAL_MIB=0
  [ "$NEED_CAM_IMAGE" = "1" ] && TOTAL_MIB=$(( TOTAL_MIB + P1_MB ))
  [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] && TOTAL_MIB=$(( TOTAL_MIB + P2_MB ))
  [ "$NEED_MUSIC_IMAGE" = "1" ] && TOTAL_MIB=$(( TOTAL_MIB + P3_MB ))
  if [ "$TOTAL_MIB" -gt "$USABLE_MIB" ]; then
    echo "错误：选定的大小超过 $GADGET_DIR 下的安全可用空间。"
    echo "可用空间:  ${USABLE_MIB} MiB（扣除 OS + 归档预留后）"
    echo "已选择:  ${TOTAL_MIB} MiB（仅计算正在创建的镜像）"
    echo "请减小行车记录仪、灯光秀和/或音乐镜像的大小。"
    exit 1
  fi
fi

# Skip preview if both images already exist
if [ "$SKIP_IMAGE_CREATION" = "0" ]; then
  echo "============================================"
  echo "预览"
  echo "============================================"
  if [ "$NEED_CAM_IMAGE" = "1" ] || [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] || [ "$NEED_MUSIC_IMAGE" = "1" ]; then
    echo "将创建以下镜像文件："
    [ "$NEED_CAM_IMAGE" = "1" ] && echo "  - 行车记录仪  : $IMG_CAM_PATH  size=$PART1_SIZE  label=$LABEL1  (读写)" || echo "  - 行车记录仪  : 已存在"
    [ "$NEED_LIGHTSHOW_IMAGE" = "1" ] && echo "  - 灯光秀 : $IMG_LIGHTSHOW_PATH  size=$PART2_SIZE  label=$LABEL2  (只读)" || echo "  - 灯光秀 : 已存在"
    if [ $MUSIC_REQUIRED -eq 1 ]; then
      if [ "$NEED_MUSIC_IMAGE" = "1" ]; then
        echo "  - 音乐     : $IMG_MUSIC_PATH  size=$PART3_SIZE  label=$LABEL3  (Tesla 只读)"
      else
        echo "  - 音乐     : 已存在"
      fi
    fi
  fi
  echo ""
  echo "镜像存储位置: $GADGET_DIR"
  echo "如果这些大小过大，Pi 可能会耗尽磁盘空间并运行异常。"
  echo ""
  read -r -p "确认使用以上大小？[y/N]: " PROCEED
  PROCEED_LC="$(printf '%s' "$PROCEED" | tr '[:upper:]' '[:lower:]')"
  case "$PROCEED_LC" in
    y|yes) echo "正在继续..." ;;
    *) echo "用户已中止。"; exit 0 ;;
  esac
  echo ""
fi

# Install prerequisites (only fetch/install if something is missing)

REQUIRED_PACKAGES=(
  parted
  dosfstools
  exfatprogs
  util-linux
  psmisc
  python3-flask
  python3-waitress
  python3-av
  python3-pil
  python3-yaml
  python3-protobuf
  python3-cryptography
  protobuf-compiler
  yq
  samba
  samba-common-bin
  ffmpeg
  watchdog
  wireless-tools
  iw
  hostapd
  dnsmasq
)

# Note on packages:
# - python3-yaml: YAML parser for config.yaml (shared config file)
# - yq: Command-line YAML processor for bash scripts (reads config.yaml)
# - python3-waitress: Production WSGI server (10-20x faster than Flask dev server)
# - python3-av: PyAV for video frame extraction
# - python3-pil: PIL/Pillow for image resizing
# - ffmpeg: Used by lock chime service for audio validation and re-encoding
# - rclone: Installed separately via official script (distro version is too old for OneDrive)
# - python3-cryptography: Fernet encryption for credential security

# Lightweight apt helpers (reduce OOM risk on Pi Zero/2W)
apt_update_safe() {
  local attempt=1
  local max_attempts=3
  while [ $attempt -le $max_attempts ]; do
    echo "正在运行 apt-get update（第 $attempt/$max_attempts 次尝试）..."
    if apt-get update \
      -o Acquire::Retries=3 \
      -o Acquire::http::No-Cache=true \
      -o Acquire::Languages=none \
      -o APT::Update::Reduce-Download-Size=true \
      -o Acquire::PDiffs=true \
      -o Acquire::http::Pipeline-Depth=0; then
      return 0
    fi
    echo "apt-get update 失败（第 $attempt 次）。正在清除列表并重试..."
    rm -rf /var/lib/apt/lists/*
    attempt=$((attempt + 1))
    sleep 2
  done
  echo "apt-get update 在 $max_attempts 次尝试后失败" >&2
  return 1
}

install_pkg_safe() {
  local pkg="$1"
  echo "正在安装 $pkg（无推荐依赖）..."
  if apt-get install -y --no-install-recommends "$pkg"; then
    return 0
  fi
  echo "正在使用默认推荐重试安装 $pkg..."
  apt-get install -y "$pkg"
}

enable_install_swap() {
  INSTALL_SWAP="/var/swap/teslausb_pkg.swap"
  if swapon --show | grep -q "$INSTALL_SWAP" 2>/dev/null; then
    echo "临时交换已激活"
    return
  fi
  echo "正在为软件包安装启用临时交换空间（1GB）..."
  # Use existing swap if available, otherwise create temporary
  if [ -f "/var/swap/fsck.swap" ] && ! swapon --show | grep -q "fsck.swap" 2>/dev/null; then
    echo "  使用现有的 fsck 交换文件"
    swapon /var/swap/fsck.swap 2>/dev/null && return
  fi
  # Create temporary 1GB swap
  mkdir -p /var/swap
  if fallocate -l 1G "$INSTALL_SWAP" 2>/dev/null || dd if=/dev/zero of="$INSTALL_SWAP" bs=1M count=1024 status=none; then
    chmod 600 "$INSTALL_SWAP"
    mkswap "$INSTALL_SWAP" >/dev/null 2>&1 || { echo "mkswap 失败"; return 1; }
    swapon "$INSTALL_SWAP" 2>/dev/null || { echo "swapon 失败"; return 1; }
    echo "  交换已启用: $(swapon --show | grep -E 'teslausb|fsck' || echo '无 - 失败')"
  else
    echo "错误：无法创建临时交换空间"
    return 1
  fi
}

disable_install_swap() {
  if [ -n "${INSTALL_SWAP-}" ] && [ -f "$INSTALL_SWAP" ]; then
    swapoff "$INSTALL_SWAP" 2>/dev/null || true
    rm -f "$INSTALL_SWAP"
  fi
}

stop_nonessential_services() {
  # Stop heavy memory users during package install (keep WiFi up)
  echo "正在停止高内存占用的服务..."
  systemctl is-active gadget_web.service >/dev/null 2>&1 && systemctl stop gadget_web.service 2>/dev/null || true
  systemctl is-active chime_scheduler.service >/dev/null 2>&1 && systemctl stop chime_scheduler.service 2>/dev/null || true
  systemctl is-active chime_scheduler.timer >/dev/null 2>&1 && systemctl stop chime_scheduler.timer 2>/dev/null || true
  systemctl is-active smbd >/dev/null 2>&1 && systemctl stop smbd 2>/dev/null || true
  systemctl is-active nmbd >/dev/null 2>&1 && systemctl stop nmbd 2>/dev/null || true
  systemctl is-active cups.service >/dev/null 2>&1 && systemctl stop cups.service 2>/dev/null || true
  systemctl is-active cups-browsed.service >/dev/null 2>&1 && systemctl stop cups-browsed.service 2>/dev/null || true
  systemctl is-active ModemManager.service >/dev/null 2>&1 && systemctl stop ModemManager.service 2>/dev/null || true
  systemctl is-active packagekit.service >/dev/null 2>&1 && systemctl stop packagekit.service 2>/dev/null || true
  systemctl is-active lightdm.service >/dev/null 2>&1 && systemctl stop lightdm.service 2>/dev/null || true
  echo "  已停止活动服务以释放内存"
}

start_nonessential_services() {
  echo "正在重启服务..."
  systemctl is-enabled smbd >/dev/null 2>&1 && systemctl start smbd 2>/dev/null || true
  systemctl is-enabled nmbd >/dev/null 2>&1 && systemctl start nmbd 2>/dev/null || true
  systemctl is-enabled chime_scheduler.timer >/dev/null 2>&1 && systemctl start chime_scheduler.timer 2>/dev/null || true
  systemctl is-enabled gadget_web.service >/dev/null 2>&1 && systemctl start gadget_web.service 2>/dev/null || true
  # Only restart if enabled (don't re-enable lightdm if we just disabled it)
  systemctl is-enabled lightdm.service >/dev/null 2>&1 && systemctl start lightdm.service 2>/dev/null || true
  systemctl is-enabled cups.service >/dev/null 2>&1 && systemctl start cups.service 2>/dev/null || true
  echo "  服务已重启"
}

# ===== Clean up old/unused services from previous installations =====
cleanup_old_services() {
  echo "正在检查来自之前安装的旧/未使用服务..."

  # Stop and disable old thumbnail generator service (replaced by on-demand generation)
  if systemctl list-unit-files | grep -q 'thumbnail_generator'; then
    echo "  正在删除旧的 thumbnail_generator 服务..."
    systemctl stop thumbnail_generator.service 2>/dev/null || true
    systemctl stop thumbnail_generator.timer 2>/dev/null || true
    systemctl disable thumbnail_generator.service 2>/dev/null || true
    systemctl disable thumbnail_generator.timer 2>/dev/null || true
    systemctl unmask thumbnail_generator.service 2>/dev/null || true
    systemctl unmask thumbnail_generator.timer 2>/dev/null || true
    rm -f /etc/systemd/system/thumbnail_generator.service
    rm -f /etc/systemd/system/thumbnail_generator.timer
    systemctl daemon-reload
    echo "    ✓ 已删除 thumbnail_generator 服务和定时器"
  fi

  # Remove old template files if they exist
  if [ -f "$GADGET_DIR/templates/thumbnail_generator.service" ] || [ -f "$GADGET_DIR/templates/thumbnail_generator.timer" ]; then
    echo "  正在删除旧的缩略图生成器模板..."
    rm -f "$GADGET_DIR/templates/thumbnail_generator.service"
    rm -f "$GADGET_DIR/templates/thumbnail_generator.timer"
    echo "    ✓ 已删除旧模板文件"
  fi

  # Remove old background thumbnail generation script
  if [ -f "$GADGET_DIR/scripts/generate_thumbnails.py" ]; then
    echo "  正在删除旧的后台缩略图生成脚本..."
    rm -f "$GADGET_DIR/scripts/generate_thumbnails.py"
    echo "    ✓ 已删除 generate_thumbnails.py"
  fi

  # Remove old wifi-powersave-off service (replaced by network-optimizations.service)
  if systemctl list-unit-files | grep -q 'wifi-powersave-off'; then
    echo "  正在删除旧的 wifi-powersave-off 服务（已被 network-optimizations 替代）..."
    systemctl stop wifi-powersave-off.service 2>/dev/null || true
    systemctl disable wifi-powersave-off.service 2>/dev/null || true
    rm -f /etc/systemd/system/wifi-powersave-off.service
    systemctl daemon-reload
    echo "    ✓ 已删除 wifi-powersave-off 服务"
  fi

  echo "旧服务清理完成。"
}

# ===== Optimize memory for setup (disable unnecessary services) =====
optimize_memory_for_setup() {
  echo "正在为安装优化内存..."

  # Disable graphical desktop services if present (saves 50-60MB on Pi Zero 2W)
  if systemctl is-enabled lightdm.service >/dev/null 2>&1; then
    echo "  正在禁用图形桌面 (lightdm)..."
    systemctl stop lightdm graphical.target 2>/dev/null || true
    systemctl disable lightdm 2>/dev/null || true
    systemctl set-default multi-user.target 2>/dev/null || true
    echo "    ✓ 图形桌面已禁用（节省约 50-60MB 内存）"
  else
    echo "  图形桌面未安装或已禁用"
  fi

  # Ensure swap is available early (critical for low-memory systems)
  if ! swapon --show 2>/dev/null | grep -q '/'; then
    echo "  未检测到活动交换空间，正在为安装启用交换空间..."

    # Try to use existing fsck swap if available
    if [ -f "/var/swap/fsck.swap" ]; then
      echo "    使用现有的 fsck.swap 文件"
      swapon /var/swap/fsck.swap 2>/dev/null && echo "    ✓ 交换已启用 (fsck.swap)" && return
    fi

    # Try to use any existing swapfile
    if [ -f "/swapfile" ]; then
      echo "    使用现有的 /swapfile"
      swapon /swapfile 2>/dev/null && echo "    ✓ 交换已启用 (/swapfile)" && return
    fi

    # Create temporary swap for setup
    echo "    正在创建临时 512MB 交换空间..."
    if dd if=/dev/zero of=/swapfile bs=1M count=512 status=none 2>/dev/null; then
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null 2>&1
      swapon /swapfile 2>/dev/null && echo "    ✓ 临时交换空间已创建并启用 (512MB)"
    else
      echo "    警告：无法创建交换空间（在低内存系统上可能导致 OOM）"
    fi
  else
    echo "  交换已激活: $(swapon --show 2>/dev/null | tail -n +2 | awk '{print $1, $3}')"
  fi

  echo "内存优化完成。"
  echo ""
}

# Run cleanup before package installation
cleanup_old_services

# Optimize memory before package installation (critical for Pi Zero/2W)
optimize_memory_for_setup

MISSING_PACKAGES=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PACKAGES+=("$pkg")
  fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
  echo "正在安装缺失的软件包: ${MISSING_PACKAGES[*]}"

  # Prepare for low-memory install
  stop_nonessential_services
  enable_install_swap || { echo "错误：启用交换空间失败。无法继续。"; exit 1; }

  # Run apt-get update
  apt_update_safe

  # Install packages one at a time to avoid OOM on low-memory systems
  for pkg in "${MISSING_PACKAGES[@]}"; do
    install_pkg_safe "$pkg" || echo "警告：安装 $pkg 时报告了错误"
  done

  # Cleanup
  disable_install_swap
  start_nonessential_services

  # Remove orphaned packages to save disk space
  echo "正在移除孤立软件包..."
  apt-get autoremove -y >/dev/null 2>&1 || true
  echo "  ✓ 孤立软件包已移除"
else
  echo "所有必需软件包已安装；跳过 apt 安装。"
fi

# Install rclone from official source (distro version is too old for OneDrive)
RCLONE_MIN_VERSION="1.65.0"
RCLONE_CURRENT=$(rclone version 2>/dev/null | head -1 | grep -oP 'v\K[0-9.]+' || echo "0.0.0")
if [ "$(printf '%s\n' "$RCLONE_MIN_VERSION" "$RCLONE_CURRENT" | sort -V | head -1)" != "$RCLONE_MIN_VERSION" ]; then
  echo "正在从官方源安装 rclone（当前版本: v${RCLONE_CURRENT}，需要 >= v${RCLONE_MIN_VERSION}）..."
  curl -sL https://rclone.org/install.sh | bash 2>/dev/null || {
    echo "警告：从官方源安装 rclone 失败，正在回退到 apt"
    apt-get install -y rclone 2>/dev/null || true
  }
  echo "  ✓ rclone $(rclone version 2>/dev/null | head -1 | grep -oP 'v[0-9.]+' || echo '已安装')"
else
  echo "rclone v${RCLONE_CURRENT} 已满足最低版本要求 v${RCLONE_MIN_VERSION}"
fi

# Ensure hostapd/dnsmasq don't auto-start outside our controller
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# Configure NetworkManager to ignore virtual AP interface (uap0)
NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_UNMANAGED_CONF="$NM_CONF_DIR/unmanaged-uap0.conf"
if [ ! -f "$NM_UNMANAGED_CONF" ]; then
  mkdir -p "$NM_CONF_DIR"
  cat > "$NM_UNMANAGED_CONF" <<EOF
[keyfile]
unmanaged-devices=interface-name:uap0
EOF
  echo "已创建 NetworkManager 配置以忽略 uap0 接口"
  if systemctl is-active --quiet NetworkManager; then
    systemctl reload NetworkManager 2>/dev/null || true
  fi
else
  echo "NetworkManager 已配置为忽略 uap0"
fi

# Configure WiFi roaming for mesh/extender networks (multiple APs with same SSID)
# NetworkManager controls wpa_supplicant via D-Bus, so we configure NM directly
NM_ROAMING_CONF="$NM_CONF_DIR/wifi-roaming.conf"
if [ ! -f "$NM_ROAMING_CONF" ]; then
  mkdir -p "$NM_CONF_DIR"
  cat > "$NM_ROAMING_CONF" <<EOF
[device]
# Enable aggressive WiFi roaming for better mesh/extender network support
wifi.scan-rand-mac-address = no

[connection]
# Disable power save to maintain better connection stability and faster roaming
# This is the most important setting for responsive roaming
wifi.powersave = 2
# Enable MAC randomization for privacy
wifi.mac-address-randomization = 1

[connectivity]
# Check connectivity frequently to detect network issues and trigger roaming
interval = 60
EOF
  echo "已创建用于 Mesh/扩展器网络的 WiFi 漫游配置"
  if systemctl is-active --quiet NetworkManager; then
    systemctl reload NetworkManager 2>/dev/null || true
  fi
else
  echo "WiFi 漫游配置已存在"
fi

# Note: NetworkManager manages wpa_supplicant directly via D-Bus (-u -s flags)
# and does not use /etc/wpa_supplicant/wpa_supplicant.conf files.
# Background scanning (bgscan) parameters are hardcoded in NetworkManager.
# The wifi.powersave=2 setting above is the key to aggressive roaming.

# ===== Detect and disable conflicting USB gadget services =====
# Raspberry Pi OS Bookworm+ ships with rpi-usb-gadget enabled by default on
# OTG-capable boards (e.g. Pi Zero 2 W). It configures a USB Ethernet gadget
# that claims the UDC, preventing TeslaUSB's mass-storage gadget from binding.
# We also check for usb-gadget.service (alternative naming on some images).
for svc in rpi-usb-gadget.service usb-gadget.service; do
  if systemctl list-unit-files "$svc" >/dev/null 2>&1 && \
     systemctl list-unit-files "$svc" | grep -q "$svc"; then
    echo "检测到冲突的服务: $svc"
    # Stop it if running (releases UDC)
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "  正在停止 $svc..."
      systemctl stop "$svc" 2>/dev/null || true
      sleep 0.5
    fi
    # Disable so it doesn't start on next boot
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
      echo "  正在禁用 $svc..."
      systemctl disable "$svc" 2>/dev/null || true
    fi
    # Mask to prevent manual/dependency activation
    echo "  正在屏蔽 $svc 以防止冲突..."
    systemctl mask "$svc" 2>/dev/null || true
    echo "  $svc 已被停止、禁用和屏蔽。"
  fi
done

# ===== Disable cloud-init (issue #74 boot speed) =====
# cloud-init delays boot by ~6s on Pi OS Bookworm and is unnecessary for a
# Pi USB gadget appliance — we don't need cloud metadata, datasource probing,
# or per-instance config. Drop the disabled flag (recognized by every cloud-init
# version) and mask the units as defense in depth.
echo "正在检查 cloud-init..."
# One glob is faster than three separate `cloud-init*`/`cloud-config*`/`cloud-final*`
# probes; the inner masking loop only touches a fixed allowlist of unit names.
if [ -d /etc/cloud ] || \
   systemctl list-unit-files 'cloud-*' --no-legend 2>/dev/null | grep -q '.'; then
  echo "正在禁用 cloud-init（Pi USB 设备不需要；启动时节省约 6 秒）..."
  mkdir -p /etc/cloud
  touch /etc/cloud/cloud-init.disabled
  for svc in cloud-init.target cloud-init.service cloud-init-local.service \
             cloud-init-main.service cloud-init-network.service \
             cloud-config.service cloud-final.service; do
    if systemctl list-unit-files "$svc" --no-legend 2>/dev/null | grep -q '.'; then
      systemctl mask "$svc" 2>/dev/null || true
    fi
  done
  # The disabled flag is the primary mechanism (recognized by every cloud-init
  # version). Masks are defense in depth. Report status based on the flag,
  # since mask failures are silently swallowed above.
  if [ -f /etc/cloud/cloud-init.disabled ]; then
    echo "  ✓ cloud-init 已禁用（标志已设置，单元尝试屏蔽）"
  else
    echo "  ⚠ cloud-init 禁用失败（无法创建 /etc/cloud/cloud-init.disabled）" >&2
  fi
else
  echo "  cloud-init 未安装；无需操作"
fi

# Also clean up any gadget left behind by rpi-usb-gadget in configfs
# (it typically creates /sys/kernel/config/usb_gadget/g1)
for other_gadget in /sys/kernel/config/usb_gadget/*/; do
  gadget_name="$(basename "$other_gadget")"
  # Skip our own gadget
  [ "$gadget_name" = "teslausb" ] && continue
  [ "$gadget_name" = "*" ] && continue
  if [ -d "$other_gadget" ]; then
    echo "正在清理残留的 USB gadget: $gadget_name"
    # Unbind UDC
    if [ -f "$other_gadget/UDC" ]; then
      echo "" > "$other_gadget/UDC" 2>/dev/null || true
      sleep 0.3
    fi
    # Remove function links from configs
    for cfg in "$other_gadget"/configs/*/; do
      [ -d "$cfg" ] || continue
      find "$cfg" -maxdepth 1 -type l -delete 2>/dev/null || true
      rmdir "$cfg"/strings/* 2>/dev/null || true
      rmdir "$cfg" 2>/dev/null || true
    done
    # Remove functions
    for func in "$other_gadget"/functions/*/; do
      [ -d "$func" ] || continue
      rmdir "$func" 2>/dev/null || true
    done
    # Remove strings and gadget
    rmdir "$other_gadget"/strings/* 2>/dev/null || true
    rmdir "$other_gadget" 2>/dev/null || true
    echo "  已移除 gadget: $gadget_name"
  fi
done

# Ensure config.txt contains dtoverlay=dwc2 and dtparam=watchdog=on under [all]
# Note: We use dtoverlay=dwc2 WITHOUT dr_mode parameter to allow auto-detection
CONFIG_CHANGED=0
if [ -f "$CONFIG_FILE" ]; then
  # Check if [all] section exists
  if grep -q '^\[all\]' "$CONFIG_FILE"; then
    # [all] section exists - check and add entries if needed

    # Check and add dtoverlay=dwc2 (only if not already present)
    if ! grep -q '^dtoverlay=dwc2$' "$CONFIG_FILE"; then
      # Add dtoverlay=dwc2 right after [all] line
      sed -i '/^\[all\]/a dtoverlay=dwc2' "$CONFIG_FILE"
      echo "已在 $CONFIG_FILE 的 [all] 部分下添加 dtoverlay=dwc2"
      CONFIG_CHANGED=1
    else
      echo "dtoverlay=dwc2 已存在于 $CONFIG_FILE"
    fi

    # Check and add dtparam=watchdog=on (only if not already present)
    if ! grep -q '^dtparam=watchdog=on$' "$CONFIG_FILE"; then
      # Add dtparam=watchdog=on right after [all] line
      sed -i '/^\[all\]/a dtparam=watchdog=on' "$CONFIG_FILE"
      echo "已在 $CONFIG_FILE 的 [all] 部分下添加 dtparam=watchdog=on"
      CONFIG_CHANGED=1
    else
      echo "dtparam=watchdog=on 已存在于 $CONFIG_FILE"
    fi

    # Reduce GPU memory to 16MB (headless system doesn't need GPU, frees 48MB RAM)
    if ! grep -q '^gpu_mem=' "$CONFIG_FILE"; then
      sed -i '/^\[all\]/a gpu_mem=16' "$CONFIG_FILE"
      echo "已在 $CONFIG_FILE 的 [all] 部分下添加 gpu_mem=16（节省 48MB 内存）"
      CONFIG_CHANGED=1
    else
      echo "gpu_mem 已在 $CONFIG_FILE 中配置"
    fi

    # Disable HDMI output (headless, saves boot time + power)
    if ! grep -q '^hdmi_blanking=' "$CONFIG_FILE"; then
      sed -i '/^\[all\]/a hdmi_blanking=2' "$CONFIG_FILE"
      echo "已在 $CONFIG_FILE 的 [all] 部分下添加 hdmi_blanking=2（禁用 HDMI 以加快启动速度）"
      CONFIG_CHANGED=1
    else
      echo "hdmi_blanking 已在 $CONFIG_FILE 中配置"
    fi

    # Disable Bluetooth (not needed for TeslaUSB, saves boot time + frees UART)
    if ! grep -q '^dtoverlay=disable-bt$' "$CONFIG_FILE"; then
      sed -i '/^\[all\]/a dtoverlay=disable-bt' "$CONFIG_FILE"
      echo "已在 $CONFIG_FILE 的 [all] 部分下添加 dtoverlay=disable-bt（禁用蓝牙）"
      CONFIG_CHANGED=1
    else
      echo "dtoverlay=disable-bt 已存在于 $CONFIG_FILE"
    fi

    # Disable onboard audio (not needed for TeslaUSB)
    if ! grep -q '^dtparam=audio=off$' "$CONFIG_FILE"; then
      sed -i '/^\[all\]/a dtparam=audio=off' "$CONFIG_FILE"
      echo "已在 $CONFIG_FILE 的 [all] 部分下添加 dtparam=audio=off（禁用板载音频）"
      CONFIG_CHANGED=1
    else
      echo "dtparam=audio=off 已存在于 $CONFIG_FILE"
    fi
  else
    # No [all] section - append it with all entries
    printf '\n[all]\ndtoverlay=dwc2\ndtparam=watchdog=on\ngpu_mem=16\nhdmi_blanking=2\ndtoverlay=disable-bt\ndtparam=audio=off\n' >> "$CONFIG_FILE"
    echo "已将包含所有 TeslaUSB 配置项的 [all] 部分追加到 $CONFIG_FILE"
    CONFIG_CHANGED=1
  fi
else
  echo "警告：未找到 $CONFIG_FILE。请确保您的 Pi 使用 /boot/firmware/config.txt"
fi

# Configure modules to load at boot via systemd
MODULES_LOAD_CONF="/etc/modules-load.d/dwc2.conf"
if [ ! -f "$MODULES_LOAD_CONF" ]; then
  echo "正在配置开机加载模块..."
  cat > "$MODULES_LOAD_CONF" <<EOF
# USB gadget modules for Tesla USB storage
dwc2
libcomposite
EOF
  echo "已创建 $MODULES_LOAD_CONF"
else
  echo "模块加载配置已存在于 $MODULES_LOAD_CONF"
fi

# Create gadget folder
mkdir -p "$GADGET_DIR"
chown "$TARGET_USER:$TARGET_USER" "$GADGET_DIR"

# Cleanup function for loop devices
cleanup_loop_devices() {
  if [ -n "${LOOP_CAM:-}" ]; then
    echo "正在清理循环设备: $LOOP_CAM"
    losetup -d "$LOOP_CAM" 2>/dev/null || true
    LOOP_CAM=""
  fi
  if [ -n "${LOOP_LIGHTSHOW:-}" ]; then
    echo "正在清理循环设备: $LOOP_LIGHTSHOW"
    losetup -d "$LOOP_LIGHTSHOW" 2>/dev/null || true
    LOOP_LIGHTSHOW=""
  fi
  if [ -n "${LOOP_MUSIC:-}" ]; then
    echo "正在清理循环设备: $LOOP_MUSIC"
    losetup -d "$LOOP_MUSIC" 2>/dev/null || true
    LOOP_MUSIC=""
  fi
}

# Create TeslaCam image (if missing)
if [ "$SKIP_IMAGE_CREATION" = "0" ] && [ "$NEED_CAM_IMAGE" = "1" ]; then
  # Set trap to cleanup on exit/error
  trap cleanup_loop_devices EXIT INT TERM

  echo "正在创建 TeslaCam 镜像 $IMG_CAM_PATH (${P1_MB}M)..."
  # Create sparse file (thin provisioned) - only allocates space as needed
  truncate -s "${P1_MB}M" "$IMG_CAM_PATH" || {
    echo "错误：创建 TeslaCam 镜像文件失败"
    exit 1
  }

  LOOP_CAM=$(losetup --find --show "$IMG_CAM_PATH") || {
    echo "错误：为 TeslaCam 创建循环设备失败"
    exit 1
  }

  # Validate loop device was created
  if [ -z "$LOOP_CAM" ] || [ ! -e "$LOOP_CAM" ]; then
    echo "错误：循环设备创建失败或设备不可访问"
    exit 1
  fi

  echo "正在使用循环设备: $LOOP_CAM"

  # Format as single filesystem - use exFAT for large drives (>32GB), FAT32 for smaller
  echo "正在格式化 TeslaCam 驱动器 (${LABEL1})..."
  if [ "$P1_MB" -gt 32768 ]; then
    echo "  使用 exFAT（驱动器大小: ${P1_MB}MB > 32GB）"
    mkfs.exfat -n "$LABEL1" "$LOOP_CAM" || {
      echo "错误：使用 exFAT 格式化 TeslaCam 驱动器失败"
      exit 1
    }
  else
    echo "  使用 FAT32（驱动器大小: ${P1_MB}MB <= 32GB）"
    mkfs.vfat -F 32 -n "$LABEL1" "$LOOP_CAM" || {
      echo "错误：使用 FAT32 格式化 TeslaCam 驱动器失败"
      exit 1
    }
  fi

  # Clean up loop device
  losetup -d "$LOOP_CAM" 2>/dev/null || true
  LOOP_CAM=""

  echo "TeslaCam 镜像已创建并格式化。"
fi

# Create Lightshow image (if missing)
if [ "$SKIP_IMAGE_CREATION" = "0" ] && [ "$NEED_LIGHTSHOW_IMAGE" = "1" ]; then
  # Set trap to cleanup on exit/error (if not already set)
  trap cleanup_loop_devices EXIT INT TERM

  echo "正在创建 Lightshow 镜像 $IMG_LIGHTSHOW_PATH (${P2_MB}M)..."
  truncate -s "${P2_MB}M" "$IMG_LIGHTSHOW_PATH" || {
    echo "错误：创建 Lightshow 镜像文件失败"
    exit 1
  }

  LOOP_LIGHTSHOW=$(losetup --find --show "$IMG_LIGHTSHOW_PATH") || {
    echo "错误：为 Lightshow 创建循环设备失败"
    exit 1
  }

  if [ -z "$LOOP_LIGHTSHOW" ] || [ ! -e "$LOOP_LIGHTSHOW" ]; then
    echo "错误：循环设备创建失败或设备不可访问"
    exit 1
  fi

  echo "正在使用循环设备: $LOOP_LIGHTSHOW"

  # Format Lightshow drive
  echo "正在格式化 Lightshow 驱动器 (${LABEL2})..."
  if [ "$P2_MB" -gt 32768 ]; then
    echo "  使用 exFAT（驱动器大小: ${P2_MB}MB > 32GB）"
    mkfs.exfat -n "$LABEL2" "$LOOP_LIGHTSHOW" || {
      echo "错误：使用 exFAT 格式化 Lightshow 驱动器失败"
      exit 1
    }
  else
    echo "  使用 FAT32（驱动器大小: ${P2_MB}MB <= 32GB）"
    mkfs.vfat -F 32 -n "$LABEL2" "$LOOP_LIGHTSHOW" || {
      echo "错误：使用 FAT32 格式化 Lightshow 驱动器失败"
      exit 1
    }
  fi

  # Clean up loop device
  losetup -d "$LOOP_LIGHTSHOW" 2>/dev/null || true
  LOOP_LIGHTSHOW=""

  echo "Lightshow 镜像已创建并格式化。"
fi

# Create Music image (if enabled and missing)
if [ "$SKIP_IMAGE_CREATION" = "0" ] && [ $MUSIC_REQUIRED -eq 1 ] && [ "${NEED_MUSIC_IMAGE:-0}" = "1" ]; then
  trap cleanup_loop_devices EXIT INT TERM

  echo "正在创建 Music 镜像 $IMG_MUSIC_PATH (${P3_MB}M)..."
  truncate -s "${P3_MB}M" "$IMG_MUSIC_PATH" || {
    echo "错误：创建 Music 镜像文件失败"
    exit 1
  }

  LOOP_MUSIC=$(losetup --find --show "$IMG_MUSIC_PATH") || {
    echo "错误：为 Music 创建循环设备失败"
    exit 1
  }

  if [ -z "$LOOP_MUSIC" ] || [ ! -e "$LOOP_MUSIC" ]; then
    echo "错误：循环设备创建失败或设备不可访问"
    exit 1
  fi

  echo "正在使用循环设备: $LOOP_MUSIC"

  # Format Music drive (Tesla prefers FAT32 for media)
  echo "正在格式化 Music 驱动器 (${LABEL3})..."
  FS_LOWER="$(printf '%s' "$MUSIC_FS" | tr '[:upper:]' '[:lower:]')"
  if [ "$FS_LOWER" = "exfat" ]; then
    mkfs.exfat -n "$LABEL3" "$LOOP_MUSIC" || {
      echo "错误：使用 exFAT 格式化 Music 驱动器失败"
      exit 1
    }
  else
    mkfs.vfat -F 32 -n "$LABEL3" "$LOOP_MUSIC" || {
      echo "错误：使用 FAT32 格式化 Music 驱动器失败"
      exit 1
    }
  fi

  losetup -d "$LOOP_MUSIC" 2>/dev/null || true
  LOOP_MUSIC=""

  echo "Music 镜像已创建并格式化。"
fi

# Clean up any remaining loop devices
cleanup_loop_devices
trap - EXIT INT TERM  # Remove trap since we're done with image creation

# Create mount points
mkdir -p "$MNT_DIR/part1" "$MNT_DIR/part2"
chown "$TARGET_USER:$TARGET_USER" "$MNT_DIR/part1" "$MNT_DIR/part2"
chmod 775 "$MNT_DIR/part1" "$MNT_DIR/part2"
if [ $MUSIC_REQUIRED -eq 1 ]; then
  mkdir -p "$MNT_DIR/part3"
  chown "$TARGET_USER:$TARGET_USER" "$MNT_DIR/part3"
  chmod 775 "$MNT_DIR/part3"
fi

# ===== Create ArchivedClips directory for RecentClips backup =====
ARCHIVE_DIR="/home/$TARGET_USER/ArchivedClips"
mkdir -p "$ARCHIVE_DIR"
chown "$TARGET_USER:$TARGET_USER" "$ARCHIVE_DIR"
chmod 775 "$ARCHIVE_DIR"
echo "归档目录位置: $ARCHIVE_DIR"

# ===== Configure Samba for authenticated user =====
# Add user to Samba with configured password
(echo "$SAMBA_PASS"; echo "$SAMBA_PASS") | sudo smbpasswd -s -a "$TARGET_USER" || true

# Backup smb.conf
SMB_CONF="/etc/samba/smb.conf"
cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%s)"

# Remove existing gadget_part1 / gadget_part2 blocks
awk '
  BEGIN{skip=0}
  /^\[gadget_part1\]/{skip=1}
  /^\[gadget_part2\]/{skip=1}
  /^\[gadget_part3\]/{skip=1}
  /^\[.*\]$/ { if(skip==1 && $0 !~ /^\[gadget_part1\]/ && $0 !~ /^\[gadget_part2\]/ && $0 !~ /^\[gadget_part3\]/) { skip=0 } }
  { if(skip==0) print }
' "$SMB_CONF" > "${SMB_CONF}.tmp" || cp "$SMB_CONF" "${SMB_CONF}.tmp"
mv "${SMB_CONF}.tmp" "$SMB_CONF"

# Configure global security settings to prevent guest access issues with Windows
# Remove or update problematic guest-related settings in [global] section
sed -i 's/^[[:space:]]*map to guest.*$/# map to guest = Bad User (disabled for Windows compatibility)/' "$SMB_CONF"
sed -i 's/^[[:space:]]*usershare allow guests.*$/# usershare allow guests = no (disabled for Windows compatibility)/' "$SMB_CONF"

# Ensure proper authentication settings are in [global] section
if ! grep -q "^[[:space:]]*security = user" "$SMB_CONF"; then
  sed -i '/^\[global\]/a \   security = user' "$SMB_CONF"
fi

# Add min protocol to ensure Windows 10/11 compatibility
if ! grep -q "server min protocol" "$SMB_CONF"; then
  sed -i '/^\[global\]/a \   server min protocol = SMB2' "$SMB_CONF"
fi

# Add NTLM authentication for Windows compatibility
if ! grep -q "ntlm auth" "$SMB_CONF"; then
  sed -i '/^\[global\]/a \   ntlm auth = ntlmv2-only' "$SMB_CONF"
fi

# Add client protocol settings
if ! grep -q "client min protocol" "$SMB_CONF"; then
  sed -i '/^\[global\]/a \   client min protocol = SMB2' "$SMB_CONF"
fi
if ! grep -q "client max protocol" "$SMB_CONF"; then
  sed -i '/^\[global\]/a \   client max protocol = SMB3' "$SMB_CONF"
fi

# Add authenticated shares
cat >> "$SMB_CONF" <<EOF

[gadget_part1]
   path = $MNT_DIR/part1
   browseable = yes
   writable = yes
   valid users = $TARGET_USER
   guest ok = no
   create mask = 0775
   directory mask = 0775

[gadget_part2]
   path = $MNT_DIR/part2
   browseable = yes
   writable = yes
   valid users = $TARGET_USER
   guest ok = no
   create mask = 0775
   directory mask = 0775
EOF

if [ $MUSIC_REQUIRED -eq 1 ]; then
cat >> "$SMB_CONF" <<EOF

[gadget_part3]
  path = $MNT_DIR/part3
  browseable = yes
  writable = yes
  valid users = $TARGET_USER
  guest ok = no
  create mask = 0775
  directory mask = 0775
EOF
fi

# Restart Samba to pick up the new config
systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd || true

# ===== Disable Samba auto-start at boot (issue #74) =====
# Samba is only needed in edit mode. Booting it eagerly costs ~4s
# (smbd waits on network-online.target). edit_usb.sh starts smbd/nmbd on
# demand when the user enters edit mode. Disable here so they don't auto-start
# at the next reboot. We do NOT stop the running daemons — if the operator
# happens to be in an edit session right now, that session keeps working.
echo "禁用 Samba 开机自启（将在编辑模式下按需启动）..."
systemctl disable smbd 2>/dev/null || true
systemctl disable nmbd 2>/dev/null || true
# Verify both services actually disabled — `disable` failures (read-only fs,
# locked unit, missing perms) are swallowed above so the message must be
# evidence-based, not blind.
smbd_state="$(systemctl is-enabled smbd 2>/dev/null || echo unknown)"
nmbd_state="$(systemctl is-enabled nmbd 2>/dev/null || echo unknown)"
if [ "$smbd_state" != "enabled" ] && [ "$nmbd_state" != "enabled" ]; then
  echo "  ✓ Samba 开机自启已禁用 (smbd=$smbd_state nmbd=$nmbd_state)"
else
  echo "  ⚠ Samba 开机自启未完全禁用 (smbd=$smbd_state nmbd=$nmbd_state)" >&2
fi

# ===== Configure scripts (no copying - run in place) =====
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/templates"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"

echo "正在验证脚本目录结构..."
if [ ! -d "$SCRIPTS_DIR/web" ]; then
  echo "错误：未在 $SCRIPTS_DIR/web 找到 scripts/web 目录"
  exit 1
fi

# GADGET_DIR is auto-derived by config.sh — verify it matches expectations
echo "使用 GADGET_DIR: $GADGET_DIR（从脚本位置自动派生）"

# Create runtime directories

# Set permissions on all scripts
chmod +x "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py 2>/dev/null || true
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
chmod +x "$SCRIPTS_DIR"/web/web_control.py 2>/dev/null || true
chmod +x "$SCRIPTS_DIR"/web/services/*.py 2>/dev/null || true
chown -R "$TARGET_USER:$TARGET_USER" "$SCRIPTS_DIR"

# Compile protobuf definitions for SEI telemetry parser
PROTO_SRC="$SCRIPTS_DIR/web/static/dashcam.proto"
PROTO_OUT="$SCRIPTS_DIR/web/services/dashcam_pb2.py"
if [ -f "$PROTO_SRC" ]; then
  echo "正在编译 SEI 解析器的 protobuf 定义..."
  protoc --python_out="$SCRIPTS_DIR/web/services/" --proto_path="$SCRIPTS_DIR/web/static" "$PROTO_SRC"
  chown "$TARGET_USER:$TARGET_USER" "$PROTO_OUT"
  echo "  ✓ dashcam_pb2.py 已编译"
fi

echo ""
echo "============================================"
echo "脚本正在从以下位置原地运行："
echo "  $SCRIPTS_DIR"
echo ""
echo "编辑配置文件："
echo "  - $SCRIPTS_DIR/config.sh (shell 脚本)"
echo "  - $SCRIPTS_DIR/web/config.py (Web 应用)"
echo "============================================"
echo ""

# ===== Configure passwordless sudo for gadget scripts =====
SUDOERS_D_DIR="/etc/sudoers.d"
SUDOERS_ENTRY="$SUDOERS_D_DIR/teslausb-gadget"
echo "正在为 gadget 脚本配置免密码 sudo..."
if [ ! -d "$SUDOERS_D_DIR" ]; then
  mkdir -p "$SUDOERS_D_DIR"
  chmod 755 "$SUDOERS_D_DIR"
fi

# Create comprehensive sudoers file for all commands used by the scripts
cat > "$SUDOERS_ENTRY" <<EOF
# Allow $TARGET_USER to run gadget control scripts and all required system commands
# without password for web interface automation

# First, allow the main scripts to run with full sudo privileges
$TARGET_USER ALL=(ALL) NOPASSWD: $GADGET_DIR/scripts/present_usb.sh
$TARGET_USER ALL=(ALL) NOPASSWD: $GADGET_DIR/scripts/edit_usb.sh
$TARGET_USER ALL=(ALL) NOPASSWD: $GADGET_DIR/scripts/ap_control.sh
$TARGET_USER ALL=(ALL) NOPASSWD: $GADGET_DIR/scripts/fsck_with_swap.sh

# Allow bash invocation of scripts (fallback when execute bit is missing)
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/bash $GADGET_DIR/scripts/*.sh

# Allow all system commands used within the scripts
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/smbcontrol
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/rmmod
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/modprobe
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/losetup
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/mount
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/umount
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/fuser
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/mkdir
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/chown
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/rm
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/fsck.vfat
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/fsck.exfat
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/sbin/blkid
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/tee
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/lsof
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/kill
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/sync
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/timeout
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/nsenter
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/sed
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/pkill
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/nmcli

# Allow cache dropping for exFAT filesystem sync (required for web lock chime updates)
# and for vfat slab-cache invalidation on the part1 RO mount before each archive
# scan (issue #71). ``echo 2`` drops slabs only (dentries+inodes) — preserves the
# page cache that backs the gadget's reads. ``echo 3`` drops both, used after
# part2 RW remounts where the page cache is already cold.
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/sh -c echo 3 > /proc/sys/vm/drop_caches
$TARGET_USER ALL=(ALL) NOPASSWD: /bin/sh -c echo 3 > /proc/sys/vm/drop_caches
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/sh -c echo 2 > /proc/sys/vm/drop_caches
$TARGET_USER ALL=(ALL) NOPASSWD: /bin/sh -c echo 2 > /proc/sys/vm/drop_caches
EOF
chmod 440 "$SUDOERS_ENTRY"

# Validate sudoers file syntax
if ! visudo -c -f "$SUDOERS_ENTRY" >/dev/null 2>&1; then
  echo "错误：生成的 sudoers 文件存在语法错误。正在回滚..."
  rm -f "$SUDOERS_ENTRY"
  exit 1
fi

echo "Sudoers 配置已成功完成。"

STATE_FILE="$GADGET_DIR/state.txt"
if [ ! -f "$STATE_FILE" ]; then
  echo "正在初始化模式状态文件..."
  echo "unknown" > "$STATE_FILE"
  chown "$TARGET_USER:$TARGET_USER" "$STATE_FILE"
fi

# ===== Systemd services =====
echo "正在安装 systemd 服务..."

# Helper function to process systemd service templates
configure_service() {
  local template_file="$1"
  local output_file="$2"

  sed -e "s|__GADGET_DIR__|$GADGET_DIR|g" \
      -e "s|__MNT_DIR__|$MNT_DIR|g" \
      -e "s|__TARGET_USER__|$TARGET_USER|g" \
      "$template_file" > "$output_file"
}

# Web UI service
SERVICE_FILE="/etc/systemd/system/gadget_web.service"
configure_service "$TEMPLATES_DIR/gadget_web.service" "$SERVICE_FILE"

# Auto-present service
AUTO_SERVICE="/etc/systemd/system/present_usb_on_boot.service"
configure_service "$TEMPLATES_DIR/present_usb_on_boot.service" "$AUTO_SERVICE"

# Safe-mode boot detection service
SAFE_MODE_SERVICE="/etc/systemd/system/teslausb-safe-mode.service"
configure_service "$TEMPLATES_DIR/teslausb-safe-mode.service" "$SAFE_MODE_SERVICE"

# Deferred boot tasks (cleanup, chime selection — runs AFTER USB is presented)
DEFERRED_SERVICE="/etc/systemd/system/teslausb-deferred-tasks.service"
configure_service "$TEMPLATES_DIR/teslausb-deferred-tasks.service" "$DEFERRED_SERVICE"

# SSH protection drop-in (prevents sshd from being stopped/masked)
for sshd_name in ssh sshd; do
  SSHD_DROPIN_DIR="/etc/systemd/system/${sshd_name}.service.d"
  if systemctl list-unit-files "${sshd_name}.service" >/dev/null 2>&1; then
    mkdir -p "$SSHD_DROPIN_DIR"
    cp "$TEMPLATES_DIR/sshd-protect.conf" "$SSHD_DROPIN_DIR/teslausb-protect.conf"
    echo "  已为 ${sshd_name}.service 安装 SSH 保护插入文件"
  fi
done

# Chime scheduler service
CHIME_SCHEDULER_SERVICE="/etc/systemd/system/chime_scheduler.service"
configure_service "$TEMPLATES_DIR/chime_scheduler.service" "$CHIME_SCHEDULER_SERVICE"

# Chime scheduler timer
CHIME_SCHEDULER_TIMER="/etc/systemd/system/chime_scheduler.timer"
configure_service "$TEMPLATES_DIR/chime_scheduler.timer" "$CHIME_SCHEDULER_TIMER"

# Phase 3b (#99): the cloud_archive_sync.timer / .service one-shot
# entry point has been removed. The continuous worker started by
# gadget_web.service replaces both: a long-lived daemon thread that
# idles on threading.Event.wait() and drains the queue on
# file-watcher events, NM dispatcher fires, mode-switch hooks, and
# manual UI clicks. Disable + remove any pre-existing units from
# previous installs so we don't keep firing the dead timer.
if systemctl list-unit-files cloud_archive_sync.timer 2>/dev/null | grep -q cloud_archive_sync; then
  echo "正在移除旧的 cloud_archive_sync.timer / .service（已被持续工作进程替代）"
  systemctl disable --now cloud_archive_sync.timer 2>/dev/null || true
  systemctl disable --now cloud_archive_sync.service 2>/dev/null || true
  rm -f /etc/systemd/system/cloud_archive_sync.timer
  rm -f /etc/systemd/system/cloud_archive_sync.service
  systemctl daemon-reload
fi

# WiFi monitor service
WIFI_MONITOR_SERVICE="/etc/systemd/system/wifi-monitor.service"
configure_service "$TEMPLATES_DIR/wifi-monitor.service" "$WIFI_MONITOR_SERVICE"

# Network optimizations service (applies runtime settings at boot)
# This handles: CPU governor, TX queue, read-ahead, RTS threshold, regulatory domain
NETWORK_OPT_SERVICE="/etc/systemd/system/network-optimizations.service"
configure_service "$TEMPLATES_DIR/network-optimizations.service" "$NETWORK_OPT_SERVICE"

# Ensure wifi-monitor.sh and optimize_network.sh are executable
chmod +x "$SCRIPT_DIR/scripts/wifi-monitor.sh"
chmod +x "$SCRIPT_DIR/scripts/optimize_network.sh" 2>/dev/null || true

# Apply network optimizations immediately during setup
if [ -f "$SCRIPT_DIR/scripts/optimize_network.sh" ]; then
  echo "正在应用网络优化..."
  "$SCRIPT_DIR/scripts/optimize_network.sh" 2>/dev/null || echo "  注意：部分优化需要重启才能生效"
fi

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable --now gadget_web.service || systemctl restart gadget_web.service

systemctl daemon-reload
systemctl enable present_usb_on_boot.service || true

# Enable safe-mode boot detection (must run before all other TeslaUSB services)
systemctl enable teslausb-safe-mode.service || true

# Enable deferred tasks (runs after USB is presented)
systemctl enable teslausb-deferred-tasks.service || true

# Ensure boot_deferred_tasks.sh is executable
chmod +x "$SCRIPT_DIR/scripts/boot_deferred_tasks.sh"

# Enable and start chime scheduler timer
systemctl enable --now chime_scheduler.timer || systemctl restart chime_scheduler.timer

# Phase 3b (#99): cloud_archive_sync.timer is gone — the continuous
# worker inside gadget_web.service handles all cloud sync triggers
# (file watcher, NM dispatcher, mode switch, manual UI). The block
# above already removed any stale unit files from previous installs.

# Enable and start WiFi monitoring service
systemctl enable --now wifi-monitor.service || systemctl restart wifi-monitor.service

# Enable network optimizations service (applies runtime settings at each boot)
systemctl enable network-optimizations.service || true

# Ensure the web service picks up the latest code changes
systemctl restart gadget_web.service || true

# Create tmpfs directory for temporary rclone config (never persisted to SD card)
mkdir -p /run/teslausb
chmod 700 /run/teslausb

# Deploy cloud token refresh dispatcher (keeps OAuth tokens alive on WiFi connect)
# NetworkManager requires dispatcher scripts to be owned by root
CLOUD_REFRESH_DISPATCHER="/etc/NetworkManager/dispatcher.d/99-teslausb-cloud-refresh"
configure_service "$TEMPLATES_DIR/99-teslausb-cloud-refresh" "$CLOUD_REFRESH_DISPATCHER"
chown root:root "$CLOUD_REFRESH_DISPATCHER" 2>/dev/null || true
chmod 755 "$CLOUD_REFRESH_DISPATCHER" 2>/dev/null || true
chmod +x "$SCRIPT_DIR/scripts/web/helpers/refresh_cloud_token.py" 2>/dev/null || true

# ===== Configure System Reliability Features =====
echo
echo "正在配置系统可靠性功能..."

# Configure sysctl for kernel panic auto-reboot and network performance
SYSCTL_CONF="/etc/sysctl.d/99-teslausb.conf"
if [ ! -f "$SYSCTL_CONF" ] || ! grep -q "kernel.panic" "$SYSCTL_CONF" 2>/dev/null; then
  echo "正在为系统可靠性和网络性能创建 sysctl 配置..."
  cat > "$SYSCTL_CONF" <<'EOF'
# TeslaUSB System Reliability Configuration

# Reboot 10 seconds after kernel panic
kernel.panic = 10

# Treat kernel oops as panic (triggers auto-reboot)
kernel.panic_on_oops = 1

# Don't panic on OOM - let OOM killer work instead
vm.panic_on_oom = 0

# Swappiness (how aggressively to use swap) - low value for SD card longevity
vm.swappiness = 10

# Network Performance Tuning (WiFi optimization)
# Increase network buffer sizes for better throughput
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# TCP buffer auto-tuning (min, default, max in bytes)
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216

# Enable TCP window scaling for high-latency networks
net.ipv4.tcp_window_scaling = 1

# Use BBR congestion control (better for WiFi/wireless)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Reduce TIME_WAIT socket timeout to free resources faster
net.ipv4.tcp_fin_timeout = 15

# Allow reuse of TIME_WAIT sockets
net.ipv4.tcp_tw_reuse = 1

# Increase max queued packets
net.core.netdev_max_backlog = 5000

# Enable TCP fast open
net.ipv4.tcp_fastopen = 3

# Note: IPv6 is left ENABLED because mDNS (.local hostname resolution) requires it
# Disabling IPv6 breaks cybertruckusb.local and similar hostnames
EOF
  chmod 644 "$SYSCTL_CONF"
  echo "  已创建 $SYSCTL_CONF"

  # Apply sysctl settings immediately
  sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 || true
  echo "  已应用 sysctl 设置"
else
  echo "Sysctl 配置已存在于 $SYSCTL_CONF"
fi

# Configure hardware watchdog
# ALWAYS overwrite with known-good config to prevent boot loops from aggressive settings
WATCHDOG_CONF="/etc/watchdog.conf"
echo "正在配置硬件看门狗..."
if [ -f "$WATCHDOG_CONF" ]; then
  cp "$WATCHDOG_CONF" "${WATCHDOG_CONF}.bak.$(date +%s)"
  echo "  已备份现有配置"
fi
cat > "$WATCHDOG_CONF" <<'EOF'
# TeslaUSB Hardware Watchdog Configuration
# Simple, reliable config for Raspberry Pi Zero 2W
#
# WARNING: Do not add aggressive settings like min-memory or repair-binary
# as they can cause boot loops on low-memory devices like Pi Zero 2W.
# See TeslaUSB readme.md for details.

# Watchdog device
watchdog-device = /dev/watchdog

# Watchdog timeout (hardware reset after 90 seconds of no response)
# Note: 90s gives headroom for transient SDIO bus contention on the
# Pi Zero 2 W (the SD card and WiFi chip share one SDIO controller).
# A heavy archive catch-up + concurrent Tesla writes + WiFi traffic
# can briefly stall the watchdog daemon; 60s was sometimes enough to
# trigger spurious reboots during 1000+ clip backlog drains.
watchdog-timeout = 90

# Reboot if 1-minute load average exceeds 24 (6x the 4 cores).
# A spiky-but-recovering workload won't trip this.
max-load-1 = 24

# Reboot if 5-minute load average exceeds 16 (4x the 4 cores).
# Catches sustained CPU/IO storms (e.g. a wedged indexer churning on
# Tesla recordings) where load stays high for several minutes but the
# 1-minute average never spikes above 24. Without this, the kernel
# watchdog daemon happily pets the dog while userspace is stuck in D
# state waiting on slow exFAT I/O.
max-load-5 = 16

# Realtime priority for watchdog daemon
realtime = yes
priority = 1
EOF
chmod 644 "$WATCHDOG_CONF"
echo "  已应用 TeslaUSB 看门狗配置"

# Issue #104 mitigation D: boost the watchdog daemon's CPU + I/O
# scheduling so a heavy archive backlog drain (which saturates the
# shared SDIO controller on the Pi Zero 2 W) cannot starve it long
# enough to miss its /dev/watchdog ping window. Without this the
# daemon inherits default Nice=0 + best-effort I/O, which a
# CPU-bound load 7+ + saturated SDIO can deprive of slices for the
# ~3-6 minutes a single contended _atomic_copy takes — long enough
# to exceed the 90s hardware-watchdog timeout. The drop-in is always
# overwritten so a corrupted prior file can't survive.
WATCHDOG_DROPIN_DIR="/etc/systemd/system/watchdog.service.d"
WATCHDOG_DROPIN_FILE="${WATCHDOG_DROPIN_DIR}/teslausb-priority.conf"
echo "正在配置 watchdog.service 优先级插入文件（问题 #104）..."
mkdir -p "$WATCHDOG_DROPIN_DIR"
cat > "$WATCHDOG_DROPIN_FILE" <<'EOF'
# TeslaUSB watchdog.service priority boost (issue #104)
#
# Why: the Pi Zero 2 W shares one SDIO controller between the SD card
# and the WiFi chip. A heavy archive backlog drain (Tesla writing
# 6 MB/s + archive reads + indexer parses + SD writes) can saturate
# the bus and CPU long enough to starve the userspace watchdog daemon
# for several minutes, missing its 90 s /dev/watchdog ping window and
# triggering a hardware reset. Boosting Nice + giving it realtime I/O
# priority makes the daemon scheduler-resilient without affecting
# correctness — it does negligible work per tick.
[Service]
Nice=-5
IOSchedulingClass=realtime
IOSchedulingPriority=0
EOF
chmod 644 "$WATCHDOG_DROPIN_FILE"
systemctl daemon-reload
echo "  已安装 $WATCHDOG_DROPIN_FILE"

# Enable and start watchdog service
echo "正在启用看门狗服务..."
systemctl enable watchdog.service || true
systemctl restart watchdog.service 2>/dev/null || echo "  注意：看门狗将在下次重启后启动（需要 dtparam=watchdog=on）"

echo "系统可靠性功能已配置。"

# ===== Create Persistent Swapfile for FSCK Operations =====
echo
echo "正在为文件系统检查创建持久交换文件..."
SWAP_DIR="/var/swap"
SWAP_FILE="$SWAP_DIR/fsck.swap"
SWAP_SIZE_MB=1024  # 1GB swap

# Handle legacy /var/swap file (move it aside if it exists as a file)
if [ -f "/var/swap" ] && [ ! -d "/var/swap" ]; then
  echo "  正在将旧版 /var/swap 文件移至 /var/swap.old..."
  swapoff /var/swap 2>/dev/null || true
  mv /var/swap /var/swap.old
fi

if [ ! -f "$SWAP_FILE" ]; then
  # Create swap directory if it doesn't exist
  if [ ! -d "$SWAP_DIR" ]; then
    mkdir -p "$SWAP_DIR"
  fi

  # Create swapfile using fallocate (faster than dd)
  echo "  正在 $SWAP_FILE 创建 1GB 交换文件..."
  fallocate -l ${SWAP_SIZE_MB}M "$SWAP_FILE" || {
    # Fallback to dd if fallocate fails
    echo "  fallocate 失败，正在改用 dd..."
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$SWAP_SIZE_MB status=progress
  }

  # Secure permissions and format as swap
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"

  echo "  ✓ 交换文件创建成功"

  # Add to /etc/fstab for automatic mounting on boot
  if ! grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
    echo "  正在将交换添加到 /etc/fstab 以实现持久挂载..."
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    systemctl daemon-reload
    echo "  ✓ 交换将在开机时自动启用"
  fi

  # Enable swap now
  swapon "$SWAP_FILE" 2>/dev/null || echo "  注意：交换已启用，将在重启后激活"

  # Clean up temporary swapfile from optimize_memory_for_setup if it exists
  if [ -f "/swapfile" ] && [ "$SWAP_FILE" != "/swapfile" ]; then
    echo "  正在清理临时 /swapfile..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    echo "  ✓ 临时交换文件已移除"
  fi

else
  echo "  交换文件已存在于 $SWAP_FILE"

  # Ensure it's in fstab even if file exists
  if ! grep -q "$SWAP_FILE" /etc/fstab 2>/dev/null; then
    echo "  正在将现有交换添加到 /etc/fstab..."
    echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
    systemctl daemon-reload
    echo "  ✓ 交换将在开机时自动启用"
  fi

  # Clean up temporary swapfile from optimize_memory_for_setup if it exists
  if [ -f "/swapfile" ] && [ "$SWAP_FILE" != "/swapfile" ]; then
    echo "  正在清理临时 /swapfile..."
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    echo "  ✓ 临时交换文件已移除"
  fi

  # Enable swap if not already active
  if ! swapon --show 2>/dev/null | grep -q "$SWAP_FILE"; then
    echo "  正在启用交换..."
    swapon "$SWAP_FILE" 2>/dev/null || true
  fi
fi

# ===== Disable Raspberry Pi OS Swap Management (we manage our own swap) =====
# These services expect /var/swap to be a FILE, but we use /var/swap/ as a DIRECTORY
# containing fsck.swap. Mask them to prevent noisy errors in logs.
echo "正在禁用 Raspberry Pi OS 交换管理服务（我们自行管理）..."
RPI_SWAP_SERVICES=(
  "rpi-resize-swap-file.service"
  "rpi-setup-loop@var-swap.service"
  "rpi-remove-swap-file@var-swap.service"
  "systemd-zram-setup@zram0.service"
  "dev-zram0.swap"
)
for service in "${RPI_SWAP_SERVICES[@]}"; do
  if systemctl list-unit-files "$service" &>/dev/null; then
    systemctl stop "$service" 2>/dev/null || true
    systemctl mask "$service" 2>/dev/null || true
  fi
done
echo "  ✓ Raspberry Pi OS 交换服务已禁用（使用我们自己的交换 $SWAP_FILE）"

# ===== Disable Unnecessary Desktop Services (Save ~30MB RAM) =====
echo
echo "正在禁用不必要的桌面服务以节省内存..."

# Stop and mask audio/color management services (not needed for headless USB gadget)
DESKTOP_SERVICES=("pipewire" "wireplumber" "pipewire-pulse" "colord")
for service in "${DESKTOP_SERVICES[@]}"; do
  if systemctl is-active "$service" >/dev/null 2>&1 || systemctl is-enabled "$service" >/dev/null 2>&1; then
    echo "  正在停止并屏蔽 $service..."
    systemctl stop "$service" 2>/dev/null || true
    systemctl mask "$service" 2>/dev/null || true
  fi
done

echo "  ✓ 桌面服务已禁用（节省约 30MB 内存）"

# Detach any stale loop devices before folder seeding
losetup -D 2>/dev/null || true

# ===== Create TeslaCam folder on TeslaCam drive =====
echo
echo "正在 TeslaCam 驱动器上设置 TeslaCam 文件夹..."
TEMP_MOUNT="/tmp/teslacam_setup_$$"
mkdir -p "$TEMP_MOUNT"

# Mount TeslaCam drive temporarily
LOOP_SETUP=$(losetup --find --show "$IMG_CAM_PATH")

# Let kernel auto-detect filesystem type
mount "$LOOP_SETUP" "$TEMP_MOUNT"

# Create TeslaCam directory if it doesn't exist
if [ ! -d "$TEMP_MOUNT/TeslaCam" ]; then
  echo "  正在创建 TeslaCam 文件夹..."
  mkdir -p "$TEMP_MOUNT/TeslaCam"
else
  echo "  TeslaCam 文件夹已存在"
fi

# Sync and unmount
sync
umount "$TEMP_MOUNT"
losetup -d "$LOOP_SETUP"
rmdir "$TEMP_MOUNT"
echo "TeslaCam 文件夹设置完成。"

# ===== 在灯光秀驱动器上创建锁车音效文件夹 =====
echo
echo "正在灯光秀驱动器上设置锁车音效文件夹..."
TEMP_MOUNT="/tmp/lightshow_setup_$$"
mkdir -p "$TEMP_MOUNT"

# Mount lightshow drive temporarily
LOOP_SETUP=$(losetup -f)
losetup "$LOOP_SETUP" "$IMG_LIGHTSHOW_PATH"
mount "$LOOP_SETUP" "$TEMP_MOUNT"

# 创建锁车音效目录
mkdir -p "$TEMP_MOUNT/Chimes"
mkdir -p "$TEMP_MOUNT/LightShow"  # Also ensure LightShow folder exists

# 迁移现有 WAV 文件（LockChime.wav 除外）到锁车音效文件夹
echo "正在迁移现有 WAV 文件到锁车音效文件夹..."
MIGRATED_COUNT=0
for wavfile in "$TEMP_MOUNT"/*.wav "$TEMP_MOUNT"/*.WAV; do
  if [ -f "$wavfile" ]; then
    filename=$(basename "$wavfile")
    # Skip LockChime.wav (case-insensitive)
    if [[ "${filename,,}" != "lockchime.wav" ]]; then
      echo "  正在移动 $filename 到锁车音效目录/"
      mv "$wavfile" "$TEMP_MOUNT/Chimes/"
      MIGRATED_COUNT=$((MIGRATED_COUNT + 1))
    fi
  fi
done

if [ $MIGRATED_COUNT -gt 0 ]; then
  echo "  已迁移 $MIGRATED_COUNT 个 WAV 文件到锁车音效文件夹"
else
  echo "  未找到需要迁移的 WAV 文件"
fi

# Sync and unmount
sync
umount "$TEMP_MOUNT"
losetup -d "$LOOP_SETUP"
rmdir "$TEMP_MOUNT"
echo "锁车音效文件夹设置完成。"

# ===== Create Music folder on Music drive =====
if [ $MUSIC_REQUIRED -eq 1 ] && [ -f "$IMG_MUSIC_PATH" ]; then
  echo
  echo "正在 Music 驱动器上设置 Music 文件夹..."
  TEMP_MOUNT="/tmp/music_setup_$$"
  mkdir -p "$TEMP_MOUNT"

  # Mount music drive temporarily
  LOOP_SETUP=$(losetup --find --show "$IMG_MUSIC_PATH")
  echo "  正在使用循环设备: $LOOP_SETUP"

  # Let kernel auto-detect filesystem type (avoids blkid misidentification on large FAT32)
  mount "$LOOP_SETUP" "$TEMP_MOUNT"

  # Create Music directory if it doesn't exist
  if [ ! -d "$TEMP_MOUNT/Music" ]; then
    echo "  正在创建 Music 文件夹..."
    mkdir -p "$TEMP_MOUNT/Music"
  else
    echo "  Music 文件夹已存在"
  fi

  # Sync and unmount
  sync
  umount "$TEMP_MOUNT"
  losetup -d "$LOOP_SETUP"
  rmdir "$TEMP_MOUNT"
  echo "Music 文件夹设置完成。"
fi

echo
echo "安装完成。"
echo " - 呈现脚本:     $GADGET_DIR/scripts/present_usb.sh"
echo " - 编辑脚本:     $GADGET_DIR/scripts/edit_usb.sh"
echo " - Web 界面:     http://<pi_ip>/  (服务: gadget_web.service)"
echo " - 开机自动呈现 USB: present_usb_on_boot.service (带可选清理功能)"
echo "Samba 共享：使用用户 '$TARGET_USER' 和在 SAMBA_PASS 中设置的密码"
echo
echo "已启用的系统可靠性功能："
echo " - 硬件看门狗：系统挂起时自动重启 (watchdog.service)"
echo " - 服务自动重启：所有服务在失败时自动重启"
echo " - 内存限制：服务受限以防止 OOM 崩溃"
echo " - 内核恐慌自动重启：10 秒超时"
echo " - WiFi 自动重连：主动监控 (wifi-monitor.service)"
echo " - WiFi 省电已禁用：防止休眠相关断连"
echo

# Load required kernel modules before presenting USB gadget
echo "正在加载 USB gadget 内核模块..."
modprobe configfs 2>/dev/null || true
modprobe libcomposite 2>/dev/null || true

# Try to load dwc2 - this might fail on first install if config.txt was just updated
if ! modprobe dwc2 2>/dev/null; then
    echo "警告：dwc2 模块尚不可用"
fi

# Ensure configfs is mounted
if ! mountpoint -q /sys/kernel/config 2>/dev/null; then
    echo "正在挂载 configfs..."
    mount -t configfs none /sys/kernel/config 2>/dev/null || true
fi

# Check if UDC is available (indicates dwc2 is working)
if [ ! -d /sys/class/udc ] || [ -z "$(ls -A /sys/class/udc 2>/dev/null)" ]; then
    echo ""
    echo "============================================"
    echo "⚠️  需要重启"
    echo "============================================"
    echo "USB gadget 硬件 (dwc2) 尚不可用。"
    echo ""
    if [ "$CONFIG_CHANGED" = "1" ]; then
        echo "原因：config.txt 刚刚被修改了 USB gadget 设置。"
        echo ""
    fi
    echo "后续步骤："
    echo "  1. 重启 Raspberry Pi：sudo reboot"
    echo "  2. 重启后，USB gadget 将自动启用"
    echo "  3. 硬件看门狗将激活以保护系统"
    echo "  4. 访问 Web 界面：http://$(hostname -I | awk '{print $1}'):$WEB_PORT/"
    echo ""
    echo "系统已配置就绪，但需要重启以激活 USB gadget 硬件支持和硬件看门狗。"
    echo "============================================"
    exit 0
fi

echo "检测到 USB gadget 硬件。正在切换到呈现模式..."
"$GADGET_DIR/scripts/present_usb.sh"
echo
echo "设置完成！Pi 现在处于呈现模式。"
