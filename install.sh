#!/usr/bin/env bash
# ==============================================================================
# Fail2Ban Modern One-Key Installer
# Repo       : https://github.com/violetaini/fail2ban-installer
# Author     : Custom maintained
# Description: 现代化一键安装与配置 Fail2Ban（先查端口、交互修改SSH端口、自动放行防火墙、免重启启动保护）
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
NON_INTERACTIVE=false

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
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=true
            shift 1
            ;;
        -h|--help)
            echo "用法: bash install.sh [选项]"
            echo "选项:"
            echo "  -p, --port <port>         指定 SSH 端口 (跳过交互询问，若与当前端口不同则自动修改)"
            echo "  -b, --bantime <seconds>   指定封禁时长，单位秒 (默认: 86400)"
            echo "  -m, --maxretry <count>    指定最大尝试次数 (默认: 3)"
            echo "  -w, --whitelist <ips>     指定忽略 IP 白名单，逗号或空格分隔"
            echo "  -y, --non-interactive     非交互静默安装模式 (保持当前端口并使用默认参数)"
            echo "  -h, --help                显示此帮助信息"
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

# 2. 自动检测当前本机 SSH 运行端口
detect_ssh_port() {
    local port=""
    
    # 策略 1: 从当前活动的 SSH 连接环境变量中读取 (最准确)
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi

    # 策略 2: 通过套接字查看 sshd / ssh.socket 正在监听的端口
    if [[ -z "$port" ]] && command -v ss >/dev/null 2>&1; then
        port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh\.socket|systemd' | grep -oE ':[0-9]+' | tr -d ':' | head -n 1 || true)
    fi

    # 策略 3: 尝试通过 sshd -T 查看实际加载的 Port
    if [[ -z "$port" ]]; then
        local sshd_cmd=""
        if command -v sshd >/dev/null 2>&1; then
            sshd_cmd="sshd"
        elif [[ -x "/usr/sbin/sshd" ]]; then
            sshd_cmd="/usr/sbin/sshd"
        fi
        if [[ -n "$sshd_cmd" ]]; then
            port=$("$sshd_cmd" -T 2>/dev/null | grep -iE '^port ' | awk '{print $2}' | head -n 1 || true)
        fi
    fi

    # 策略 4: 从配置文件中查找未被注释的 Port 行
    if [[ -z "$port" ]]; then
        port=$(grep -rhE '^[ \t]*Port[ \t]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
    fi

    # 兜底默认值
    if [[ -z "$port" ]]; then
        port="22"
    fi

    echo "$port"
}

# 修改本机 SSH 端口函数
change_ssh_port() {
    local target_port="$1"
    info "正在将系统 SSH 服务端口修改为: $target_port ..."

    local ssh_cfg="/etc/ssh/sshd_config"
    if [[ ! -f "$ssh_cfg" ]]; then
        err "未找到 $ssh_cfg 配置文件，无法自动修改系统 SSH 端口！"
        return 1
    fi

    # 1. 备份配置文件
    local backup_cfg="${ssh_cfg}.bak-$(date +%Y%m%d%H%M%S)"
    cp "$ssh_cfg" "$backup_cfg"
    info "已备份原 SSH 配置至: $backup_cfg"

    # 2. 修改配置文件的 Port
    if grep -qE '^[ \t]*Port[ \t]+[0-9]+' "$ssh_cfg"; then
        sed -i -E "s/^[ \t]*Port[ \t]+[0-9]+/Port $target_port/" "$ssh_cfg"
    elif grep -qE '^[ \t]*#?[ \t]*Port[ \t]+' "$ssh_cfg"; then
        sed -i -E "s/^[ \t]*#?[ \t]*Port[ \t]+[0-9]*/Port $target_port/" "$ssh_cfg"
    else
        echo "Port $target_port" >> "$ssh_cfg"
    fi

    # 3. 语法检测保险机制 (sshd -t)
    local sshd_bin=""
    if command -v sshd >/dev/null 2>&1; then
        sshd_bin="sshd"
    elif [[ -x "/usr/sbin/sshd" ]]; then
        sshd_bin="/usr/sbin/sshd"
    fi

    if [[ -n "$sshd_bin" ]]; then
        if ! "$sshd_bin" -t 2>/dev/null; then
            err "sshd 配置语法检查未通过！正在自动回滚配置文件..."
            cp "$backup_cfg" "$ssh_cfg"
            err "修改失败，已还原配置。建议您检查 $ssh_cfg 后手动修改。"
            exit 1
        fi
    fi

    # 4. 防火墙自动放行 (UFW / Firewalld)
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        info "检测到 UFW 防火墙处于激活状态，正在放行新端口 $target_port/tcp ..."
        ufw allow "${target_port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        info "检测到 Firewalld 防火墙处于运行状态，正在放行新端口 $target_port/tcp ..."
        firewall-cmd --permanent --add-port="${target_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    # 5. 重启 SSH 服务生效
    info "正在重启 SSH 服务以应用新端口..."
    local restarted=false
    if command -v systemctl >/dev/null 2>&1; then
        for svc in ssh sshd; do
            if systemctl is-active "$svc" >/dev/null 2>&1 || systemctl is-enabled "$svc" >/dev/null 2>&1; then
                if systemctl restart "$svc" 2>/dev/null; then
                    restarted=true
                    break
                fi
            fi
        done
        if [[ "$restarted" == "false" ]]; then
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            restarted=true
        fi
    elif command -v service >/dev/null 2>&1; then
        service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
        restarted=true
    fi

    echo ""
    echo -e "${GREEN}================================================================${PLAIN}"
    ok "系统 SSH 端口已成功更改为: ${CYAN}${target_port}${PLAIN}"
    warn "【重要安全警告】当前登录会话不会断开！"
    warn "在关闭此终端前，请务必【新开一个窗口】测试能否通过新端口登录："
    warn "👉 ssh -p ${target_port} $(whoami)@<您的服务器IP>"
    echo -e "${GREEN}================================================================${PLAIN}"
    echo ""
}

CURRENT_PORT=$(detect_ssh_port)
SSH_PORT="$CURRENT_PORT"

# 3. 询问是否修改 SSH 端口与确认最终端口
if [[ -n "$CUSTOM_PORT" ]]; then
    if [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] && [ "$CUSTOM_PORT" -ge 1 ] && [ "$CUSTOM_PORT" -le 65535 ]; then
        if [[ "$CUSTOM_PORT" != "$CURRENT_PORT" ]]; then
            info "检测到命令行指定了新端口: $CUSTOM_PORT (当前为: $CURRENT_PORT)，正在执行更改..."
            change_ssh_port "$CUSTOM_PORT"
            SSH_PORT="$CUSTOM_PORT"
        else
            info "命令行指定端口与当前运行端口一致 ($CUSTOM_PORT)，无需修改 SSH 配置。"
            SSH_PORT="$CUSTOM_PORT"
        fi
    else
        err "命令行指定的端口号无效: $CUSTOM_PORT (必须为 1-65535 的整数)"
        exit 1
    fi
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
    info "非交互模式，保持当前 SSH 端口: $SSH_PORT"
else
    # 交互模式：先提示当前端口，并询问是否修改
    input_source="/dev/stdin"
    if [[ -r "/dev/tty" && -c "/dev/tty" ]]; then
        input_source="/dev/tty"
    fi

    echo ""
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"
    echo -e "${CYAN}[*] 当前检测到本机 SSH 监听端口为: ${GREEN}${CURRENT_PORT}${PLAIN}"
    echo -e "${CYAN}----------------------------------------------------${PLAIN}"

    while true; do
        echo -en "是否需要修改本机 SSH 端口？[y/N] (直接回车默认不修改): "
        CHANGE_CHOICE=""
        read -r CHANGE_CHOICE < "$input_source" || CHANGE_CHOICE=""
        CHANGE_CHOICE=$(echo "${CHANGE_CHOICE:-n}" | tr '[:upper:]' '[:lower:]')

        if [[ "$CHANGE_CHOICE" == "y" || "$CHANGE_CHOICE" == "yes" ]]; then
            while true; do
                echo -en "请输入新的 SSH 端口号 [建议范围 1025-65534]: "
                NEW_PORT_INPUT=""
                read -r NEW_PORT_INPUT < "$input_source" || NEW_PORT_INPUT=""

                if [[ "$NEW_PORT_INPUT" =~ ^[0-9]+$ ]] && [ "$NEW_PORT_INPUT" -ge 1 ] && [ "$NEW_PORT_INPUT" -le 65535 ]; then
                    if [[ "$NEW_PORT_INPUT" == "$CURRENT_PORT" ]]; then
                        warn "输入的端口与当前端口相同 ($CURRENT_PORT)，无需修改。"
                        SSH_PORT="$CURRENT_PORT"
                        break
                    fi
                    change_ssh_port "$NEW_PORT_INPUT"
                    SSH_PORT="$NEW_PORT_INPUT"
                    break
                else
                    err "端口号无效！请输入 1 到 65535 之间的纯数字。"
                fi
            done
            break
        elif [[ "$CHANGE_CHOICE" == "n" || "$CHANGE_CHOICE" == "no" || -z "$CHANGE_CHOICE" ]]; then
            ok "保持原 SSH 端口不变: $SSH_PORT"
            break
        else
            err "输入错误，请仅输入 y 或 n！"
        fi
    done
    echo ""
fi

# 4. 检测系统发行版与包管理器
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

# 5. 安装 Fail2Ban 原生包与必要依赖
info "正在安装系统原生 fail2ban 依赖包..."
case "$PKG_MGR" in
    apt)
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        # 同时安装 python3-systemd 与 iptables 确保 Debian 12 / Ubuntu 24.04+ 下 systemd 后端无缝工作
        apt install -y fail2ban python3-systemd iptables
        ;;
    dnf|yum)
        $PKG_MGR install -y epel-release || true
        $PKG_MGR install -y fail2ban fail2ban-systemd iptables
        ;;
    apk)
        apk update
        apk add fail2ban iptables
        ;;
    pacman)
        pacman -Sy --noconfirm fail2ban iptables
        ;;
esac

ok "Fail2ban 核心程序包及依赖安装完成！"

# 6. 自动配置白名单（本机 + 当前登录客户端 IP）
CLIENT_IP=""
if [[ -n "${SSH_CLIENT:-}" ]]; then
    CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    CLIENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
fi

IGNORE_IPS="127.0.0.1/8 ::1"
if [[ -n "$CLIENT_IP" && "$CLIENT_IP" != "127.0.0.1" ]]; then
    IGNORE_IPS="$IGNORE_IPS $CLIENT_IP"
    info "已将您当前连接的客户端 IP ($CLIENT_IP) 加入白名单，防止误封！"
fi
if [[ -n "$CUSTOM_WHITELIST" ]]; then
    SANITIZED_WHITELIST=$(echo "$CUSTOM_WHITELIST" | tr ',' ' ')
    IGNORE_IPS="$IGNORE_IPS $SANITIZED_WHITELIST"
    info "已追加指定白名单: $SANITIZED_WHITELIST"
fi

# 7. 生成现代化的 /etc/fail2ban/jail.local
info "正在生成高兼容 jail.local 配置文件..."
mkdir -p /etc/fail2ban

# 备份旧配置
if [[ -f /etc/fail2ban/jail.local ]]; then
    cp /etc/fail2ban/jail.local "/etc/fail2ban/jail.local.bak-$(date +%Y%m%d%H%M%S)"
fi

# 智能检测后端日志模式（检查 systemd 与 python-systemd 支持）
BACKEND="systemd"
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import systemd' >/dev/null 2>&1; then
    BACKEND="auto"
elif ! command -v journalctl >/dev/null 2>&1; then
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

# 8. 确保运行时目录存在
mkdir -p /run/fail2ban /var/run/fail2ban

# 9. 启用并立即启动服务（免重启）
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

# 10. 状态检验
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
