# Server Scripts

新增 `alpine-toolbox.sh`，提供独立的数字菜单，不合并或修改仓库原有脚本。以 root 身份在目标容器的交互终端运行：

```sh
curl -fsSL https://raw.githubusercontent.com/podcctv/server-scripts/main/alpine-toolbox.sh | sh
```

- `1`：检测、安装 Alpine OpenSSH，开启 root 密码登录。二级菜单 `1` 保持原密码（默认），`2` 生成 10 位密码，保证包含大小写字母、数字及 `@%_+=` 中的符号，不含引号、反斜杠、美元符号、反引号等易引起转义或展开的字符。
- `2`：补齐 Bash/curl 依赖，下载并运行 [上游 sing-box 安装脚本](https://github.com/caigouzi121380/singbox-deploy)。执行上游 main 最新代码，具体安装行为由上游维护；下载或语法检查失败时不执行。
- `0`：退出。

通过 `/dev/tty` 读取输入，支持 `curl | sh`；远程执行需分配终端（如 `ssh -t`）。Alpine 尚未安装 curl 时，先运行 `apk add --no-cache curl ca-certificates`。SSH 功能在当前 Alpine 系统内执行，不批量进入其他容器。

## SSH 行为

保留当前端口和其他配置，默认端口由 OpenSSH 配置决定，通常为 22。原配置备份为 `/etc/ssh/sshd_config.backup.*`，写入前先检查配置语法及本地 root 的有效认证设置。重复运行会替换已有管理块。

启用 `PermitRootLogin yes`、`PasswordAuthentication yes` 和 `AuthenticationMethods any`，允许仅使用密码认证。原有针对不同地址的 Match、AllowUsers、DenyUsers、PAM 或账户限制仍可能阻止登录；完成后请从另一终端实际验证。公网使用应限制可信来源。

不修改密码时不会解锁账户，也无法显示原密码。选择新密码后会立即显示一次；即使后续服务启动失败，新密码仍然生效。脚本不将密码写入日志文件，但终端录屏或会话日志可能记录输出。

运行中的 OpenRC 环境使用服务管理及开机启动；普通容器通过 PID 文件重载现有 sshd 或直接启动，不批量杀死 SSH 会话。没有 OpenRC 的容器需自行配置入口进程保证重启后启动 SSH；端口映射、防火墙和容器持久化也需在宿主机配置。

本入口暂不提供端口、密码长度或禁用 root 的参数。

## 仓库其他脚本

- `alpine-ssh-final-repair-incus-podma-final.sh`：宿主机上的 Incus / Podman Alpine SSH 修复工具。
- `install-abuse-guard.sh`：原有 abuse guard 安装脚本。
