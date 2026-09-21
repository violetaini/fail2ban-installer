#!/usr/bin/env bash
# ==============================================================================
# Fail2Ban Modern One-Key Installer
# Repo       : https://github.com/your-username/fail2ban-installer
# Author     : Custom maintained
# Description: 现代化一键安装与配置 Fail2Ban（免重启、自动检测端口、兼容 Debian/Ubuntu/RHEL/CentOS/Rocky）
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

info()  { echo -e "${BLUE}[INFO]${PLAIN} $*"; }
ok()    { echo -e "${GREEN}[OK]${PLAIN} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${PLAIN} $*"; }
err()   { echo -e "${RED}[ERROR]${PLAIN} $*" >&2; }

# 默认安全参数
DEFAULT_BANTIME=86400     # 封禁时长：24小时 (秒)
DEFAULT_FINDTIME=600      # 统计周期：10分钟 (秒)
DEFAULT_MAXRETRY=3        # 最大失败次数：3次
CUSTOM_PORT=""
CUSTOM_WHITELIST=""

# 解析可选命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)
            CUSTOM_PORT="$2"
            shift 2
            ;;
        -b|--bantime)
            DEFAULT_BANTIME="$2"
            shift 2
            ;;
        -m|--maxretry)
            DEFAULT_MAXRETRY="$2"
            shift 2
            ;;
        -w|--whitelist)
            CUSTOM_WHITELIST="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: bash install.sh [选项]"
            echo "选项:"
            echo "  -p, --port <port>         指定 SSH 端口 (默认自动检测当前监听端口)"
            echo "  -b, --bantime <seconds>   指定封禁时长，单位秒 (默认: 86400)"
            echo "  -m, --maxretry <count>    指定最大尝试次数 (默认: 3)"
            echo "  -w, --whitelist <ips>     指定忽略 IP 白名单，逗号分隔"
            exit 0
            ;;
        *)
            err "未知参数: $1"
            exit 1
            ;;
    esac
done

# 1. 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    err "请使用 root 权限运行此安装脚本！"
    exit 1
fi

echo -e "${CYAN}====================================================${PLAIN}"
echo -e "${CYAN}           Fail2Ban 现代化高兼容一键安装程序           ${PLAIN}"
echo -e "${CYAN}====================================================${PLAIN}"

# 2. 检测系统发行版与包管理器
info "正在识别系统架构与包管理器..."
OS_TYPE=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_TYPE=$ID
fi

case "$OS_TYPE" in
    debian|ubuntu)
        info "检测到 Debian/Ubuntu 系系统 ($PRETTY_NAME)"
        PKG_MGR="apt"
        ;;
    centos|rhel|rocky|almalinux|fedora)
        info "检测到 RHEL/CentOS 系系统 ($PRETTY_NAME)"
        if command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        else
            PKG_MGR="yum"
        fi
        ;;
    alpine)
        info "检测到 Alpine Linux"
        PKG_MGR="apk"
        ;;
    arch)
        info "检测到 Arch Linux"
        PKG_MGR="pacman"
        ;;
    *)
        warn "未精确识别发行版 ($OS_TYPE)，尝试常规 apt/dnf 检测..."
        if command -v apt >/dev/null 2>&1; then
            PKG_MGR="apt"
        elif command -v dnf >/dev/null 2>&1; then
            PKG_MGR="dnf"
        elif command -v yum >/dev/null 2>&1; then
            PKG_MGR="yum"
        else
            err "不支持的包管理器，请手动安装 fail2ban"
            exit 1
        fi
        ;;
esac

# 3. 安装 Fail2Ban 原生包
info "正在安装系统原生 fail2ban 依赖包..."
case "$PKG_MGR" in
    apt)
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt install -y fail2ban
        ;;
    dnf|yum)
        $PKG_MGR install -y epel-release || true
        $PKG_MGR install -y fail2ban fail2ban-systemd
        ;;
    apk)
        apk update
        apk add fail2ban
        ;;
    pacman)
        pacman -Sy --noconfirm fail2ban
        ;;
esac

ok "Fail2ban 核心程序包安装完成！"

# 4. 自动检测 SSH 实际运行端口
if [[ -n "$CUSTOM_PORT" ]]; then
    SSH_PORT="$CUSTOM_PORT"
    info "使用用户指定的 SSH 端口: $SSH_PORT"
else
    info "正在自动检测 SSH 当前监听端口..."
    SSH_PORT=""
    if command -v sshd >/dev/null 2>&1; then
        SSH_PORT=$(sshd -T 2>/dev/null | grep -iE '^port ' | awk '{print $2}' || true)
    fi
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT=$(grep -rhE '^[# ]*Port ' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | grep -v '#' | awk '{print $2}' | tail -n 1 || true)
    fi
    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT="22"
    fi
    ok "自动检测到 SSH 端口为: $SSH_PORT"
fi

# 5. 自动配置白名单（本机 + 当前登录 IP）
CLIENT_IP=""
if [[ -n "${SSH_CLIENT:-}" ]]; then
    CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
fi

IGNORE_IPS="127.0.0.1/8 ::1"
if [[ -n "$CLIENT_IP" && "$CLIENT_IP" != "127.0.0.1" ]]; then
    IGNORE_IPS="$IGNORE_IPS $CLIENT_IP"
    info "已将您当前连接的客户端 IP ($CLIENT_IP) 加入白名单，防止误封！"
fi
if [[ -n "$CUSTOM_WHITELIST" ]]; then
    IGNORE_IPS="$IGNORE_IPS $CUSTOM_WHITELIST"
    info "已追加指定白名单: $CUSTOM_WHITELIST"
fi

# 6. 生成现代化的 /etc/fail2ban/jail.local
info "正在生成高兼容 jail.local 配置文件..."
mkdir -p /etc/fail2ban

# 备份旧配置
if [[ -f /etc/fail2ban/jail.local ]]; then
    cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak-$(date +%Y%m%d%H%M%S)"
fi

# 检测后端日志模式（优先 systemd）
BACKEND="systemd"
if ! command -v journalctl >/dev/null 2>&1; then
    BACKEND="auto"
fi

cat << EOF > /etc/fail2ban/jail.local
# ==============================================================================
# Fail2Ban Local Configuration
# Automatically generated by fail2ban-installer
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# ==============================================================================

[DEFAULT]
# 白名单 IP 列表（不予封禁）
ignoreip = ${IGNORE_IPS}

# 封禁时长 (秒)
bantime = ${DEFAULT_BANTIME}

# 统计周期窗口 (秒)
findtime = ${DEFAULT_FINDTIME}

# 触发封禁的最大失败尝试次数
maxretry = ${DEFAULT_MAXRETRY}

# 日志检索后端
backend = ${BACKEND}

# 默认封禁动作
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
maxretry = ${DEFAULT_MAXRETRY}
findtime = ${DEFAULT_FINDTIME}
bantime = ${DEFAULT_BANTIME}
EOF

ok "配置文件 /etc/fail2ban/jail.local 生成成功！"

# 7. 确保运行时目录存在
mkdir -p /run/fail2ban /var/run/fail2ban

# 8. 启用并立即启动服务（免重启）
info "正在重载 systemd 并启动 fail2ban 服务..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl unmask fail2ban 2>/dev/null || true
    systemctl enable fail2ban
    systemctl restart fail2ban
elif command -v rc-service >/dev/null 2>&1; then
    rc-update add fail2ban default
    rc-service fail2ban restart
elif command -v service >/dev/null 2>&1; then
    service fail2ban restart
fi

sleep 1

# 9. 状态检验
info "正在验证 Fail2Ban 运行状态..."
if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
        echo ""
        ok "============================================================"
        ok " Fail2Ban 安装并配置成功！服务已实时处于保护运行状态！"
        ok " - 保护端口: ${SSH_PORT}"
        ok " - 失败阈值: ${DEFAULT_MAXRETRY} 次"
        ok " - 封禁时长: ${DEFAULT_BANTIME} 秒"
        ok " - 统计周期: ${DEFAULT_FINDTIME} 秒"
        ok " - 排除白名单: ${IGNORE_IPS}"
        ok "============================================================"
        echo ""
        fail2ban-client status sshd
    else
        warn "Fail2ban 已启动，但 sshd jail 尚未就绪，输出全局状态："
        fail2ban-client status || true
    fi
else
    warn "未能检测到 fail2ban-client 命令，请检查服务日志。"
fi

echo ""
info "常用管理命令指引："
echo "  - 查看保护状态: fail2ban-client status sshd"
echo "  - 解封指定 IP : fail2ban-client set sshd unbanip <IP>"
echo "  - 手动封禁 IP : fail2ban-client set sshd banip <IP>"
echo "  - 查看实时日志: tail -f /var/log/fail2ban.log"
