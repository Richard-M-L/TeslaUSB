#!/bin/bash
set -euo pipefail

# TeslaUSB Upgrade Script
# This script pulls the latest code from GitHub and runs setup
# Supports both git-cloned installations and manual installations

REPO_URL="https://github.com/Richard-M-L/TeslaUSB"
ARCHIVE_BASE_URL="https://github.com/Richard-M-L/TeslaUSB/archive/refs/heads"
# Auto-derive install directory from this script's location (run-in-place)
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="main"
BACKUP_DIR=""

# Cleanup function for error handling
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        echo ""
        echo "============================================"
        echo "错误：升级失败，退出代码 $exit_code"
        echo "============================================"
        echo ""
        echo "正在从备份恢复：$BACKUP_DIR"

        # Restore backed up files
        if [ -f "$BACKUP_DIR/state.txt" ]; then
            cp "$BACKUP_DIR/state.txt" "$INSTALL_DIR/" 2>/dev/null || true
        fi
        if [ -d "$BACKUP_DIR/thumbnails" ]; then
            rm -rf "$INSTALL_DIR/thumbnails"
            cp -r "$BACKUP_DIR/thumbnails" "$INSTALL_DIR/" 2>/dev/null || true
        fi

        echo "备份已恢复。"
        echo "正在删除备份目录..."
        rm -rf "$BACKUP_DIR"
        echo "备份目录已删除。"
        echo ""
        echo "系统已恢复到之前的状态。"
        exit $exit_code
    fi
}

# Set trap for error handling (only for non-git path)
trap cleanup_on_error EXIT

echo "==================================="
echo "TeslaUSB 升级脚本"
echo "==================================="
echo ""

# Store current mode state if it exists
if [ -f "$INSTALL_DIR/state.txt" ]; then
    CURRENT_MODE=$(cat "$INSTALL_DIR/state.txt")
    echo "当前模式：$CURRENT_MODE"
else
    CURRENT_MODE="unknown"
fi
echo ""

# Check if this is a git repository
if [ -d "$INSTALL_DIR/.git" ]; then
    echo "检测到 Git 仓库——使用 git pull 方式更新"
    echo ""

    cd "$INSTALL_DIR"

    echo "当前目录：$(pwd)"
    echo "当前分支：$(git branch --show-current)"
    echo ""

    # Fetch latest changes
    echo "正在从 GitHub 获取最新更新..."
    git fetch origin

    # Reset any local changes to tracked files (including chmod changes)
    echo "正在重置跟踪文件的本地更改..."
    git reset --hard origin/$BRANCH

    # Clean up any untracked files (optional - commented out for safety)
    # git clean -fd

else
    echo "未检测到 Git 仓库——使用直接下载方式更新"
    echo ""

    # Create backup directory with timestamp
    BACKUP_DIR="${INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
    echo "正在创建备份：$BACKUP_DIR"

    # Backup important files
    mkdir -p "$BACKUP_DIR"
    [ -f "$INSTALL_DIR/state.txt" ] && cp "$INSTALL_DIR/state.txt" "$BACKUP_DIR/"
    [ -f "$INSTALL_DIR/usb_cam.img" ] && echo "保留 usb_cam.img（因体积较大，不进行备份）"
    [ -f "$INSTALL_DIR/usb_lightshow.img" ] && echo "保留 usb_lightshow.img（因体积较大，不进行备份）"
    [ -d "$INSTALL_DIR/thumbnails" ] && cp -r "$INSTALL_DIR/thumbnails" "$BACKUP_DIR/"

    echo ""
    echo "正在从 GitHub 下载最新文件..."
    TEMP_DIR=$(mktemp -d)
    ARCHIVE_FILE="$TEMP_DIR/repo.tar.gz"
    EXTRACT_DIR="$TEMP_DIR/src"
    mkdir -p "$EXTRACT_DIR"

    ARCHIVE_DOWNLOAD_URL="${ARCHIVE_BASE_URL}/${BRANCH}.tar.gz"
    echo "正在下载压缩包：$ARCHIVE_DOWNLOAD_URL"
    curl -fsSL "$ARCHIVE_DOWNLOAD_URL" -o "$ARCHIVE_FILE" || { echo "下载仓库压缩包失败"; exit 1; }

    echo "正在解压压缩包..."
    tar -xzf "$ARCHIVE_FILE" -C "$EXTRACT_DIR" --strip-components=1 || { echo "解压仓库压缩包失败"; exit 1; }

    echo "正在复制文件到 $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    cp -a "$EXTRACT_DIR/." "$INSTALL_DIR/" || { echo "复制文件到安装目录失败"; exit 1; }

    # Restore state file if it was backed up
    if [ -f "$BACKUP_DIR/state.txt" ]; then
        cp "$BACKUP_DIR/state.txt" "$INSTALL_DIR/"
    fi

    # Clean up temp directory
    rm -rf "$TEMP_DIR"

    echo ""
    echo "文件更新成功！"

    # Delete backup if we got here successfully
    if [ -d "$BACKUP_DIR" ]; then
        echo "正在删除备份（升级成功）..."
        rm -rf "$BACKUP_DIR"
        echo "备份已删除。"
    fi
fi

# Disable error trap for git-based updates (they handle their own errors)
trap - EXIT

# Ensure scripts are executable
echo ""
echo "正在设置脚本执行权限..."
chmod +x "$INSTALL_DIR/setup_usb.sh"
chmod +x "$INSTALL_DIR/cleanup.sh"
chmod +x "$INSTALL_DIR/upgrade.sh"

echo ""
echo "==================================="
echo "代码更新成功！"
echo "==================================="
echo ""

# Ask user if they want to run setup
read -p "Do you want to run setup_usb.sh now? [y/n]: " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "正在运行 setup_usb.sh..."
    sudo ./setup_usb.sh

    echo ""
    echo "==================================="
    echo "升级完成！"
    echo "==================================="

    # Restore previous mode if it was in edit mode
    if [ "$CURRENT_MODE" = "edit" ]; then
        echo ""
        echo "之前为「编辑」模式。如需切换回编辑模式，请确认。"
        read -p "Switch to edit mode now? [y/n]: " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo ./scripts/edit_usb.sh
        fi
    fi
else
    echo ""
    echo "跳过 setup。您可以稍后手动运行："
    echo "  cd $INSTALL_DIR && sudo ./setup_usb.sh"
fi

echo ""
echo "升级流程结束！"
