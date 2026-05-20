#!/bin/bash
set -euo pipefail

REPO_URL="https://github.com/Richard-M-L/TeslaUSB"
ARCHIVE_BASE_URL="https://github.com/Richard-M-L/TeslaUSB/archive/refs/heads"
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="main"
BACKUP_DIR=""
STATUS_FILE="/tmp/teslausb_upgrade_status.json"
NON_INTERACTIVE=0

# Status helpers — write JSON so the web API can poll it
_write_status() {
  local phase="$1" msg="$2" pct="${3:-0}" code="${4:-0}"
  printf '{"phase":"%s","message":"%s","pct":%d,"code":%d}\n' \
    "$phase" "$msg" "$pct" "$code" > "$STATUS_FILE"
}

_error_status() {
  local msg="$1"
  printf '{"phase":"error","message":"%s","pct":0,"code":1}\n' "$msg" > "$STATUS_FILE"
  exit 1
}

# Cleanup function for error handling (non-git path only)
cleanup_on_error() {
  local exit_code=$?
  if [ $exit_code -ne 0 ] && [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
    echo "升级失败，正在从备份恢复: $BACKUP_DIR"
    [ -f "$BACKUP_DIR/state.txt" ] && cp "$BACKUP_DIR/state.txt" "$INSTALL_DIR/" 2>/dev/null || true
    if [ -d "$BACKUP_DIR/thumbnails" ]; then
      rm -rf "$INSTALL_DIR/thumbnails"
      cp -r "$BACKUP_DIR/thumbnails" "$INSTALL_DIR/" 2>/dev/null || true
    fi
    rm -rf "$BACKUP_DIR"
    echo "备份已恢复。"
  fi
  _error_status "升级失败 (exit $exit_code)"
}

# ─────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=1 ;;
    *) ;;
  esac
  shift
done

# ─────────────────────────────────────────────────────────────
# Check if git repo
# ─────────────────────────────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  IS_GIT=1
else
  IS_GIT=0
fi

if [ "$NON_INTERACTIVE" -eq 1 ] && [ "$IS_GIT" -eq 0 ]; then
  _error_status "非 Git 安装不支持在线升级，请手动运行 upgrade.sh"
fi

# ─────────────────────────────────────────────────────────────
# Banner (interactive only)
# ─────────────────────────────────────────────────────────────
if [ "$NON_INTERACTIVE" -eq 0 ]; then
  echo "==================================="
  echo "TeslaUSB 升级脚本"
  echo "==================================="
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Store current mode
# ─────────────────────────────────────────────────────────────
if [ -f "$INSTALL_DIR/state.txt" ]; then
  CURRENT_MODE=$(cat "$INSTALL_DIR/state.txt")
else
  CURRENT_MODE="unknown"
fi

if [ "$NON_INTERACTIVE" -eq 0 ]; then
  echo "当前模式：$CURRENT_MODE"
  echo ""
fi

# ─────────────────────────────────────────────────────────────
# Git path
# ─────────────────────────────────────────────────────────────
if [ "$IS_GIT" -eq 1 ]; then
  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    echo "检测到 Git 仓库——使用 git pull 方式更新"
    echo ""
    echo "当前目录：$INSTALL_DIR"
    echo "当前分支：$(git -C "$INSTALL_DIR" branch --show-current)"
    echo ""
  fi

  cd "$INSTALL_DIR"

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    _write_status "fetch" "正在检查更新..." 10
  else
    echo "正在从 GitHub 获取最新更新..."
  fi

  # Fetch + capture old HEAD for change detection
  OLD_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "")
  git -c safe.directory="$INSTALL_DIR" fetch origin 2>&1 || _error_status "git fetch 失败，请检查网络连接"
  NEW_HEAD=$(git rev-parse origin/$BRANCH 2>/dev/null || echo "")

  if [ "$OLD_HEAD" = "$NEW_HEAD" ] && [ -n "$OLD_HEAD" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      _write_status "done" "已是最新版本" 100 2
      exit 2
    fi
    echo "已是最新版本。"
    exit 0
  fi

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    _write_status "pull" "正在下载更新..." 40
  fi

  git reset --hard origin/$BRANCH 2>&1 || _error_status "git reset 失败"

  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    _write_status "analyze" "正在分析变更..." 60
  fi

  # Determine what changed between old and new HEAD
  CHANGED_FILES=$(git diff --name-only "$OLD_HEAD" "$NEW_HEAD" 2>/dev/null || echo "")
  SYSTEM_CHANGED=0
  WEB_ONLY=1

  for f in $CHANGED_FILES; do
    # If a file outside scripts/web/ changed, it's a system-level change
    case "$f" in
      scripts/web/*|scripts/web/templates/*|scripts/web/static/*|scripts/web/translations/*)
        ;;  # web-only — fine
      *)
        SYSTEM_CHANGED=1
        WEB_ONLY=0
        ;;
    esac
  done

  # Ensure scripts are executable
  chmod +x "$INSTALL_DIR/setup_usb.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/cleanup.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/upgrade.sh" 2>/dev/null || true
  chmod +x "$INSTALL_DIR/scripts"/*.sh 2>/dev/null || true

  # ── Decide quick vs full ──
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    if [ "$WEB_ONLY" -eq 1 ]; then
      # Quick upgrade: just restart the web service
      _write_status "restart" "正在重启 Web 服务..." 80
      sudo systemctl restart gadget_web.service 2>&1 || _error_status "服务重启失败"
      _write_status "done" "升级完成（仅前端/后端代码更新）" 100 0
    else
      _write_status "done" "代码已更新，涉及系统配置变更，请 SSH 执行 sudo ./setup_usb.sh" 100 3
    fi
    exit 0
  fi

  echo ""
  echo "==================================="
  echo "代码更新成功！"
  echo "==================================="
  echo ""

  # Interactive: ask about setup
  read -p "是否运行 setup_usb.sh? [y/n]: " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo ./setup_usb.sh
    if [ "$CURRENT_MODE" = "edit" ]; then
      read -p "之前为编辑模式，是否切回? [y/n]: " -n 1 -r
      echo ""
      [[ $REPLY =~ ^[Yy]$ ]] && sudo ./scripts/edit_usb.sh
    fi
  else
    echo "跳过 setup。可手动运行: cd $INSTALL_DIR && sudo ./setup_usb.sh"
    # Restart web service for the new code to take effect
    sudo systemctl restart gadget_web.service
  fi

  echo ""
  echo "升级流程结束！"

# ─────────────────────────────────────────────────────────────
# Non-git path (interactive only)
# ─────────────────────────────────────────────────────────────
else
  trap cleanup_on_error EXIT

  BACKUP_DIR="${INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
  echo "正在创建备份：$BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
  [ -f "$INSTALL_DIR/state.txt" ] && cp "$INSTALL_DIR/state.txt" "$BACKUP_DIR/"
  [ -d "$INSTALL_DIR/thumbnails" ] && cp -r "$INSTALL_DIR/thumbnails" "$BACKUP_DIR/"

  echo "正在从 GitHub 下载最新文件..."
  TEMP_DIR=$(mktemp -d)
  ARCHIVE_FILE="$TEMP_DIR/repo.tar.gz"
  EXTRACT_DIR="$TEMP_DIR/src"
  mkdir -p "$EXTRACT_DIR"

  curl -fsSL "${ARCHIVE_BASE_URL}/${BRANCH}.tar.gz" -o "$ARCHIVE_FILE" || _error_status "下载失败"
  tar -xzf "$ARCHIVE_FILE" -C "$EXTRACT_DIR" --strip-components=1 || _error_status "解压失败"

  echo "正在复制文件..."
  mkdir -p "$INSTALL_DIR"
  cp -a "$EXTRACT_DIR/." "$INSTALL_DIR/" || _error_status "复制失败"

  [ -f "$BACKUP_DIR/state.txt" ] && cp "$BACKUP_DIR/state.txt" "$INSTALL_DIR/"
  rm -rf "$TEMP_DIR"

  if [ -d "$BACKUP_DIR" ]; then
    rm -rf "$BACKUP_DIR"
  fi

  trap - EXIT

  chmod +x "$INSTALL_DIR/setup_usb.sh"
  chmod +x "$INSTALL_DIR/cleanup.sh"
  chmod +x "$INSTALL_DIR/upgrade.sh"

  echo ""
  echo "==================================="
  echo "代码更新成功！"
  echo "==================================="
  echo ""

  read -p "是否运行 setup_usb.sh? [y/n]: " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo ./setup_usb.sh
    if [ "$CURRENT_MODE" = "edit" ]; then
      read -p "之前为编辑模式，是否切回? [y/n]: " -n 1 -r
      echo ""
      [[ $REPLY =~ ^[Yy]$ ]] && sudo ./scripts/edit_usb.sh
    fi
  else
    echo "跳过 setup。可手动运行: cd $INSTALL_DIR && sudo ./setup_usb.sh"
    sudo systemctl restart gadget_web.service
  fi

  echo ""
  echo "升级流程结束！"
fi
