# Fail2Ban Modern Installer

现代化、高兼容性的 Fail2Ban 一键安装与维护脚本。完美适配现代 Linux 系统（Debian 10/11/12/13、Ubuntu 20.04/22.04/24.04、CentOS/RHEL/Rocky Linux 7/8/9）。

针对历史老脚本（如 FunctionClub 等）痛点全面重构：
- ✅ **免重启生效**：安装完成后自动注册 systemd 并立即启动防护，无需重启机器。
- ✅ **自动识别 SSH 端口**：支持自定义高位端口（如 30222），不再死板绑定 22 端口。
- ✅ **智能防误封**：自动抓取当前 SSH 客户端 IP 加入白名单，防止自己被误封。
- ✅ **原生依赖**：使用系统官方发行版二进制包，绝不篡改系统 Python 解释器或引入废弃的 distutils。
- ✅ **现代日志检索**：优先适配 `systemd journal`，完美兼容取消了 `/var/log/auth.log` 的新版 Debian/Ubuntu。

---

## 🚀 快速开始

### 一键安装（推荐）

```bash
bash <(curl -sSL https://raw.githubusercontent.com/your-username/fail2ban-installer/main/install.sh)
```
*(将 `your-username` 替换为您自己的 GitHub 用户名)*

### 自定义参数安装

```bash
# 指定 SSH 端口为 30222，最大重试 5 次，封禁时长 48 小时 (172800秒)，追加白名单
bash install.sh -p 30222 -m 5 -b 172800 -w "1.1.1.1,2.2.2.2"
```

#### 参数说明
| 参数 | 长参数 | 默认值 | 作用 |
| :--- | :--- | :---: | :--- |
| `-p` | `--port` | 自动检测 | 指定被保护的 SSH 监听端口 |
| `-m` | `--maxretry` | `3` | 触发封禁的最大连续失败次数 |
| `-b` | `--bantime` | `86400` (24h) | IP 封禁时长（秒） |
| `-w` | `--whitelist` | 自动包含当前登录IP | 追加不予封禁的 IP 白名单（逗号分隔） |

---

## 🛠️ 常用运维命令

```bash
# 查看 Fail2ban 总体状态及受保护的 Jail 列表
fail2ban-client status

# 查看 SSH 防护的详细状态（当前封禁 IP 列表、尝试次数）
fail2ban-client status sshd

# 解封指定 IP
fail2ban-client set sshd unbanip <IP地址>

# 手动拉黑封禁指定 IP
fail2ban-client set sshd banip <IP地址>

# 查看实时拦截日志
tail -f /var/log/fail2ban.log
```

---

## 🗑️ 一键卸载

```bash
bash <(curl -sSL https://raw.githubusercontent.com/your-username/fail2ban-installer/main/uninstall.sh)
```

---

## 📄 License
[MIT License](./LICENSE)
