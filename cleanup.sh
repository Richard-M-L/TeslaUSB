#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Tesla USB 设备清理脚本
# ============================================
# 本脚本安全移除 setup_usb.sh 创建的所有文件和配置，
# 同时确保系统资源和服务的正确清理。

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载配置文件
if [ -f "$SCRIPT_DIR/scripts/config.sh" ]; then
  source "$SCRIPT_DIR/scripts/config.sh"
else
  echo "错误：在 $SCRIPT_DIR/scripts/config.sh 未找到配置文件"
  echo "使用默认值..."
  # 如果 config.sh 不存在，使用默认值
  GADGET_DIR="$SCRIPT_DIR"
  IMG_CAM_NAME="usb_cam.img"
  IMG_LIGHTSHOW_NAME="usb_lightshow.img"
  MNT_DIR="/mnt/gadget"
  SMB_CONF="/etc/samba/smb.conf"
  CONFIG_FILE="/boot/firmware/config.txt"
  TARGET_USER="${SUDO_USER:-$(whoami)}"
fi

# 计算镜像路径
IMG_CAM_PATH="$GADGET_DIR/$IMG_CAM_NAME"
IMG_LIGHTSHOW_PATH="$GADGET_DIR/$IMG_LIGHTSHOW_NAME"

echo "Tesla USB 设备清理脚本"
echo "==============================="
echo "设备目录：$GADGET_DIR"
echo "TeslaCam 镜像：$IMG_CAM_PATH"
echo "灯光秀镜像：  $IMG_LIGHTSHOW_PATH"

# 函数：安全停止并禁用 systemd 服务
cleanup_service() {
  local service_name="$1"
  local service_file="$2"

  echo "正在清理服务：$service_name"

  # 如果服务正在运行则停止
  if systemctl is-active --quiet "$service_name" 2>/dev/null; then
    echo "  正在停止 $service_name..."
    systemctl stop "$service_name" || true
  fi

  # 如果服务已启用则禁用
  if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
    echo "  正在禁用 $service_name..."
    systemctl disable "$service_name" || true
  fi

  # 删除服务文件
  if [ -f "$service_file" ]; then
    echo "  正在删除服务文件：$service_file"
    rm -f "$service_file" || true
  fi
}


# 函数：清理 USB 设备和 loop 设备
cleanup_usb_gadget() {
  echo "正在清理 USB 设备和 loop 设备..."

  # 如果 present_usb.sh 正在运行则停止
  if [ -f "$GADGET_DIR/scripts/present_usb.sh" ]; then
    echo "  正在停止 USB 设备（如已激活）..."
    "$GADGET_DIR/scripts/present_usb.sh" stop 2>/dev/null || true
  fi

  # 删除 USB 设备 configfs（如存在）
  if [ -d /sys/kernel/config/usb_gadget/pi_usb ]; then
    echo "  正在删除 USB 设备配置..."
    # 如果已绑定 UDC 则解除绑定
    if [ -f /sys/kernel/config/usb_gadget/pi_usb/UDC ]; then
      echo "" > /sys/kernel/config/usb_gadget/pi_usb/UDC 2>/dev/null || true
    fi
    # 删除配置
    rm -rf /sys/kernel/config/usb_gadget/pi_usb 2>/dev/null || true
  fi

  # 卸载已挂载的分区（编辑模式）
  echo "  正在卸载编辑模式分区..."
  for mp in "$MNT_DIR/part1" "$MNT_DIR/part2"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      echo "    正在卸载 $mp"
      umount "$mp" || true
    fi
  done

  # 卸载已挂载的只读分区（展示模式）
  echo "  正在卸载只读分区..."
  for mp in "$MNT_DIR/part1-ro" "$MNT_DIR/part2-ro"; do
    if mountpoint -q "$mp" 2>/dev/null; then
      echo "    正在卸载 $mp"
      umount "$mp" || true
    fi
  done

  # 分离两个镜像的 loop 设备
  echo "  正在分离 loop 设备..."
  for img in "$IMG_CAM_PATH" "$IMG_LIGHTSHOW_PATH"; do
    if [ -f "$img" ]; then
      for loop in $(losetup -j "$img" 2>/dev/null | cut -d: -f1); do
        if [ -n "$loop" ]; then
          echo "    正在分离 $loop"
          losetup -d "$loop" 2>/dev/null || true
        fi
      done
    fi
  done
}

# 函数：清理 Samba 配置
cleanup_samba() {
  echo "正在清理 Samba 配置..."

  if [ -f "$SMB_CONF" ]; then
    # 从 smb.conf 中删除 gadget_part1 和 gadget_part2 共享
    echo "  正在从 $SMB_CONF 中删除设备共享..."

    # 修改前创建备份
    cp "$SMB_CONF" "${SMB_CONF}.cleanup_backup.$(date +%s)" 2>/dev/null || true

    # 使用 awk 删除设备共享段落
    awk '
      BEGIN{skip=0}
      /^\[gadget_part1\]/{skip=1; next}
      /^\[gadget_part2\]/{skip=1; next}
      /^\[.*\]$/ {
        if(skip==1 && $0 !~ /^\[gadget_part1\]/ && $0 !~ /^\[gadget_part2\]/) {
          skip=0
        }
      }
      { if(skip==0) print }
    ' "$SMB_CONF" > "${SMB_CONF}.tmp" && mv "${SMB_CONF}.tmp" "$SMB_CONF" || true

    # 删除 Samba 用户
    echo "  正在删除 Samba 用户：$TARGET_USER"
    smbpasswd -x "$TARGET_USER" 2>/dev/null || true

    # 重启 Samba 以应用更改
    echo "  正在重启 Samba 服务..."
    systemctl restart smbd nmbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
  fi
}

# 函数：清理系统配置文件
cleanup_system_configs() {
  echo "正在清理系统配置文件..."

  # 删除 NetworkManager uap0 忽略配置
  if [ -f "/etc/NetworkManager/conf.d/unmanaged-uap0.conf" ]; then
    echo "  正在删除 NetworkManager uap0 配置..."
    rm -f /etc/NetworkManager/conf.d/unmanaged-uap0.conf
    systemctl reload NetworkManager 2>/dev/null || true
  fi

  # 删除模块加载配置
  if [ -f "/etc/modules-load.d/dwc2.conf" ]; then
    echo "  正在删除模块加载配置..."
    rm -f /etc/modules-load.d/dwc2.conf
  fi

  # 删除 sudoers 配置
  if [ -f "/etc/sudoers.d/teslausb-gadget" ]; then
    echo "  正在删除 sudoers 配置..."
    rm -f /etc/sudoers.d/teslausb-gadget
  fi

  # 删除 sysctl 配置
  if [ -f "/etc/sysctl.d/99-teslausb.conf" ]; then
    echo "  正在删除 sysctl 配置..."
    rm -f /etc/sysctl.d/99-teslausb.conf
    sysctl --system >/dev/null 2>&1 || true
  fi

  # 恢复看门狗配置（仅当被我们修改过时）
  if [ -f "/etc/watchdog.conf" ]; then
    if grep -q "TeslaUSB Hardware Watchdog Configuration" /etc/watchdog.conf 2>/dev/null; then
      echo "  正在恢复默认看门狗配置..."
      # 仅删除我们的自定义配置 - watchdog 软件包将使用默认值
      rm -f /etc/watchdog.conf
    fi
  fi

  # 恢复 config.txt（从 [all] 段删除 dwc2 和 watchdog 条目）
  if [ -f "$CONFIG_FILE" ]; then
    echo "  正在恢复 $CONFIG_FILE..."
    cp "$CONFIG_FILE" "${CONFIG_FILE}.cleanup_backup.$(date +%s)" 2>/dev/null || true

    # 删除 dtoverlay=dwc2 和 dtparam=watchdog=on 行
    sed -i '/^dtoverlay=dwc2$/d' "$CONFIG_FILE"
    sed -i '/^dtparam=watchdog=on$/d' "$CONFIG_FILE"

    echo "    已删除 dwc2 overlay 和看门狗参数"
  fi
}

# 函数：清理交换文件
cleanup_swap() {
  echo "正在清理交换文件..."

  # 禁用并删除持久交换文件
  if [ -f "/var/swap/fsck.swap" ]; then
    echo "  正在删除持久交换文件..."
    swapoff /var/swap/fsck.swap 2>/dev/null || true
    rm -f /var/swap/fsck.swap

    # 如果 /etc/fstab 中存在则删除
    if grep -q "/var/swap/fsck.swap" /etc/fstab 2>/dev/null; then
      echo "  正在从 /etc/fstab 中删除交换条目..."
      sed -i '\|/var/swap/fsck.swap|d' /etc/fstab
    fi
  fi

  # 如果交换目录为空则删除
  if [ -d "/var/swap" ]; then
    rmdir /var/swap 2>/dev/null || true
  fi
}

# 函数：恢复桌面服务
restore_desktop_services() {
  echo "正在恢复桌面服务..."

  # 取消屏蔽被屏蔽的桌面服务
  local desktop_services=("pipewire" "wireplumber" "pipewire-pulse" "colord")
  for service in "${desktop_services[@]}"; do
    if systemctl is-masked "${service}.service" >/dev/null 2>&1; then
      echo "  正在取消屏蔽 ${service}.service..."
      systemctl unmask "${service}.service" 2>/dev/null || true
    fi
  done

  # 如果我们在安装过程中屏蔽了 rpi-usb-gadget 则取消屏蔽
  for svc in rpi-usb-gadget.service usb-gadget.service; do
    if systemctl is-masked "$svc" >/dev/null 2>&1; then
      echo "  正在取消屏蔽 $svc（恢复 Raspberry Pi OS 默认值）..."
      systemctl unmask "$svc" 2>/dev/null || true
      systemctl enable "$svc" 2>/dev/null || true
    fi
  done

  # 检查是否将默认目标改为了 multi-user
  if systemctl get-default 2>/dev/null | grep -q "multi-user.target"; then
    echo "  正在将默认目标恢复为 graphical.target..."
    systemctl set-default graphical.target 2>/dev/null || true

    # 如果 lightdm 存在则重新启用
    if systemctl list-unit-files | grep -q "lightdm.service"; then
      echo "  正在重新启用 lightdm..."
      systemctl enable lightdm 2>/dev/null || true
    fi
  fi
}

# 函数：删除挂载目录
cleanup_mount_dirs() {
  echo "正在清理挂载目录..."

  for dir in "$MNT_DIR/part1" "$MNT_DIR/part2" "$MNT_DIR/part1-ro" "$MNT_DIR/part2-ro" "$MNT_DIR"; do
    if [ -d "$dir" ]; then
      echo "  正在删除目录：$dir"
      rmdir "$dir" 2>/dev/null || true
    fi
  done
}

# 函数：删除设备目录文件
cleanup_gadget_files() {
  echo "正在清理设备目录文件..."

  # 删除状态文件
  if [ -f "$GADGET_DIR/state.txt" ]; then
    echo "  正在删除 state.txt"
    rm -f "$GADGET_DIR/state.txt"
  fi

  # 删除所有备份文件或日志
  echo "  正在删除备份和临时文件..."
  rm -f "$GADGET_DIR"/*.bak "$GADGET_DIR"/*.tmp "$GADGET_DIR"/*.log 2>/dev/null || true
}

# 函数：删除镜像文件（可选）
# 警告：此为破坏性操作。IMG 文件包含用户数据。
# 仅在完全卸载时使用 — 正常操作中绝不使用。
cleanup_images() {
  local remove_images="$1"

  if [ "$remove_images" = "yes" ]; then
    echo "⚠️  正在删除磁盘镜像文件（用户明确请求完全清理）..."
    echo "  这将永久删除所有 TeslaCam 录像和灯光秀数据。"

    if [ -f "$IMG_CAM_PATH" ]; then
      echo "  正在删除 TeslaCam 镜像：$IMG_CAM_PATH"
      rm -f "$IMG_CAM_PATH"
    fi

    if [ -f "$IMG_LIGHTSHOW_PATH" ]; then
      echo "  正在删除灯光秀镜像：$IMG_LIGHTSHOW_PATH"
      rm -f "$IMG_LIGHTSHOW_PATH"
    fi
  else
    echo "✓ 保留磁盘镜像文件（受保护）："
    [ -f "$IMG_CAM_PATH" ] && echo "  - $IMG_CAM_PATH"
    [ -f "$IMG_LIGHTSHOW_PATH" ] && echo "  - $IMG_LIGHTSHOW_PATH"
  fi
}

# 主清理流程
main() {
  local remove_images="$1"

  echo
  echo "正在开始清理流程..."
  echo

  # 确保以 root 身份运行以进行系统清理
  if [ "$EUID" -ne 0 ]; then
    echo "错误：此脚本必须以 root 身份运行（请使用 sudo）"
    echo "用法：sudo $0"
    exit 1
  fi

  # 第 1 步：停止并禁用所有 systemd 服务
  echo "第 1 步：正在清理 systemd 服务"
  cleanup_service "gadget_web.service" "/etc/systemd/system/gadget_web.service"
  cleanup_service "present_usb_on_boot.service" "/etc/systemd/system/present_usb_on_boot.service"
  cleanup_service "chime_scheduler.service" "/etc/systemd/system/chime_scheduler.service"
  cleanup_service "chime_scheduler.timer" "/etc/systemd/system/chime_scheduler.timer"
  cleanup_service "wifi-powersave-off.service" "/etc/systemd/system/wifi-powersave-off.service"
  cleanup_service "wifi-monitor.service" "/etc/systemd/system/wifi-monitor.service"

  # 如果 hostapd 和 dnsmasq 正在运行则停止
  echo "  正在停止 hostapd 和 dnsmasq..."
  systemctl stop hostapd 2>/dev/null || true
  systemctl stop dnsmasq 2>/dev/null || true

  # 删除服务文件后重新加载 systemd
  echo "  正在重新加载 systemd 守护进程..."
  systemctl daemon-reload || true

  echo

  # 第 2 步：清理 USB 设备和 loop 设备
  echo "第 2 步：正在清理 USB 设备和 loop 设备"
  cleanup_usb_gadget
  echo

  # 第 3 步：清理 Samba 配置
  echo "第 3 步：正在清理 Samba 配置"
  cleanup_samba
  echo

  # 第 4 步：清理系统配置文件
  echo "第 4 步：正在清理系统配置文件"
  cleanup_system_configs
  echo

  # 第 5 步：清理交换文件
  echo "第 5 步：正在清理交换文件"
  cleanup_swap
  echo

  # 第 6 步：恢复桌面服务
  echo "第 6 步：正在恢复桌面服务"
  restore_desktop_services
  echo

  # 第 7 步：删除挂载目录
  echo "第 7 步：正在清理挂载目录"
  cleanup_mount_dirs
  echo

  # 第 8 步：删除设备文件
  echo "第 8 步：正在清理设备目录文件"
  cleanup_gadget_files
  echo

  # 第 9 步：删除镜像文件（可选）
  echo "第 9 步：磁盘镜像清理"
  cleanup_images "$remove_images"
  echo

  echo "============================================"
  echo "清理成功完成！"
  echo "============================================"
  echo
  echo "已执行的操作汇总："
  echo "  ✓ 已停止并删除 systemd 服务"
  echo "  ✓ 已删除 USB 设备配置"
  echo "  ✓ 已清理 Samba 共享和用户"
  echo "  ✓ 已删除系统配置文件"
  echo "  ✓ 已删除持久交换文件"
  echo "  ✓ 已恢复桌面服务（如适用）"
  echo "  ✓ 已删除挂载目录"
  echo "  ✓ 已删除设备文件"
  if [ "$remove_images" = "yes" ]; then
    echo "  ✓ 已删除磁盘镜像文件"
  else
    echo "  ✓ 已保留磁盘镜像文件"
  fi
  echo
  echo "完成清理后："
  echo "  1. 重启 Pi 以恢复原始启动配置"
  echo "  2. 可选：删除已安装的软件包："
  echo "     sudo apt remove --autoremove python3-flask python3-waitress \\"
  echo "          python3-av python3-pil samba samba-common-bin ffmpeg \\"
  echo "          watchdog hostapd dnsmasq"
  echo
  echo "备注：此清理脚本保留在 $GADGET_DIR"
  echo "      scripts/ 和 templates/ 目录也被保留"
  echo "      如不再需要，您可以手动删除它们。"
  echo
}

# 确认提示
echo
echo "这将删除所有 USB 设备配置并恢复您的 Pi。"
echo
echo "以下项目将被清理："
echo "  - 所有 systemd 服务（gadget_web、chime_scheduler、wifi-monitor 等）"
echo "  - USB 设备配置和 loop 设备"
echo "  - Samba 共享配置和用户"
echo "  - 系统配置文件（NetworkManager、modules、sudoers、sysctl）"
echo "  - 持久交换文件"
echo "  - /boot/firmware/config.txt 的修改（dwc2、看门狗）"
echo "  - 挂载目录（$MNT_DIR）"
echo "  - $GADGET_DIR 中生成的文件"
echo

# 询问磁盘镜像
REMOVE_IMAGES="no"
if [ -f "$IMG_CAM_PATH" ] || [ -f "$IMG_LIGHTSHOW_PATH" ]; then
  echo "找到磁盘镜像文件："
  [ -f "$IMG_CAM_PATH" ] && echo "  - $IMG_CAM_PATH（$(du -h "$IMG_CAM_PATH" 2>/dev/null | cut -f1)）"
  [ -f "$IMG_LIGHTSHOW_PATH" ] && echo "  - $IMG_LIGHTSHOW_PATH（$(du -h "$IMG_LIGHTSHOW_PATH" 2>/dev/null | cut -f1)）"
  echo
  read -p "是否要删除这些镜像文件？(y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    REMOVE_IMAGES="yes"
    echo "镜像文件将被删除。"
  else
    echo "镜像文件将被保留。"
  fi
  echo
fi

read -p "您确定要继续清理吗？(y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  main "$REMOVE_IMAGES"
else
  echo "清理已取消。"
  exit 0
fi
