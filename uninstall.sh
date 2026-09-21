#!/usr/bin/env bash
# ==============================================================================
# Fail2Ban One-Key Uninstaller
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

info()  { echo -e "${BLUE}[INFO]${PLAIN} $*"; }
ok()    { echo -e "${GREEN}[OK]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
err()   { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此卸载脚本！"
    exit 1
fi

info "正在停止并清理 Fail2Ban..."

# 1. 停止并禁用服务
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
elif command -v service >/dev/null 2>&1; then
    service fail2ban stop 2>/dev/null || true
fi

# 2. 备份现有配置
if [[ -d /etc/fail2ban ]]; then
    BACKUP_DIR="/root/fail2ban_backup_$(date +%Y%m%d%H%M%S)"
    cp -r /etc/fail2ban "$BACKUP_DIR"
    info "已将旧配置备份至: $BACKUP_DIR"
fi

# 3. 卸载程序包
OS_TYPE=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

case "$OS_TYPE" in
    debian|ubuntu)
        apt-get purge -y fail2ban || true
        apt-get autoremove -y || true
        ;;
    centos|rhel|rocky|almalinux|fedora)
        if command -v dnf >/dev/null 2>&1; then
            dnf remove -y fail2ban || true
        else
            yum remove -y fail2ban || true
        fi
        ;;
    alpine)
        apk del fail2ban || true
        ;;
    arch)
        pacman -R --noconfirm fail2ban || true
        ;;
esac

# 4. 清理残留文件
rm -rf /run/fail2ban /var/run/fail2ban /var/log/fail2ban.log*

ok "Fail2Ban 卸载完成！"
