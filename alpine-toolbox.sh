#!/bin/sh
# Run inside the target container, including via curl ... | sh.
set -eu
export LC_ALL=C
umask 077

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ask() { printf '%s' "$1" >&2; IFS= read -r REPLY <&3 || die '无法读取选择'; }

generate_password() {
    while :; do
        PASS=$(tr -dc 'A-Za-z0-9@%_+=' </dev/urandom | head -c 10)
        [ "${#PASS}" -eq 10 ] || continue
        case "$PASS" in *[A-Z]*) ;; *) continue ;; esac
        case "$PASS" in *[a-z]*) ;; *) continue ;; esac
        case "$PASS" in *[0-9]*) ;; *) continue ;; esac
        case "$PASS" in *[@%_+=]*) ;; *) continue ;; esac
        printf '%s' "$PASS"
        return
    done
}

setup_ssh() {
    [ -f /etc/alpine-release ] || die 'SSH 初始化功能仅支持 Alpine Linux，请在目标容器内运行。'
    printf '\n将启用 root 登录和密码认证，保留现有 SSH 端口。\n1) 不修改密码（默认）\n2) 生成新的 10 位复杂密码\n'
    while :; do
        ask '请选择 [1/2，默认 1]: '
        case "$REPLY" in ''|1) CHANGE_PASSWORD=0; break ;; 2) CHANGE_PASSWORD=1; break ;; *) printf '请输入 1 或 2\n' ;; esac
    done
    if command -v sshd >/dev/null 2>&1; then
        printf '检测到 OpenSSH。\n'
    else
        printf '未检测到 OpenSSH，正在安装。\n'
    fi
    apk add --no-cache openssh
    ssh-keygen -A
    SSHD=$(command -v sshd)
    CONFIG=/etc/ssh/sshd_config
    BACKUP=$(mktemp /etc/ssh/sshd_config.backup.XXXXXX)
    cp -p "$CONFIG" "$BACKUP"
    CANDIDATE=$(mktemp /etc/ssh/sshd_config.new.XXXXXX)
    # First value wins; place the managed global settings before Include/Match.
    {
        printf '# BEGIN server-scripts SSH settings\nPermitRootLogin yes\nPasswordAuthentication yes\nAuthenticationMethods any\n# END server-scripts SSH settings\n'
        sed '/^# BEGIN server-scripts SSH settings$/,/^# END server-scripts SSH settings$/d' "$CONFIG"
    } > "$CANDIDATE"
    if ! "$SSHD" -t -f "$CANDIDATE"; then
        rm -f "$CANDIDATE"
        die "配置校验失败，原配置未修改；备份：$BACKUP"
    fi
    EFFECTIVE=$("$SSHD" -T -f "$CANDIDATE" -C user=root,host=localhost,addr=127.0.0.1)
    for SETTING in 'permitrootlogin yes' 'passwordauthentication yes' 'authenticationmethods any'; do
        if ! printf '%s\n' "$EFFECTIVE" | grep -qx "$SETTING"; then
            rm -f "$CANDIDATE"
            die "现有 Match 规则覆盖了 $SETTING，请先检查配置；原配置未修改。"
        fi
    done
    cat "$CANDIDATE" > "$CONFIG"
    rm -f "$CANDIDATE"
    if [ "$CHANGE_PASSWORD" -eq 1 ]; then
        PASS=$(generate_password)
        if ! printf 'root:%s\n' "$PASS" | chpasswd; then
            cp -p "$BACKUP" "$CONFIG"
            die '修改密码失败，SSH 配置已恢复。'
        fi
        printf '\nroot 新密码：%s\n请立即保存；后续服务操作失败也不会撤销此密码。\n' "$PASS"
        unset PASS
    else
        printf 'root 密码未修改；若账户无密码或被锁定，需要先设置密码才能登录。\n'
    fi
    printf 'SSH 配置备份：%s\n' "$BACKUP"
    if [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1; then
        if ! rc-update add sshd default; then
            printf '[WARN] 未能设置开机启动。\n'
        fi
        if rc-service sshd status >/dev/null 2>&1; then
            rc-service sshd reload || die 'SSH 重载失败，请检查服务日志。'
        else
            rc-service sshd start || die 'SSH 启动失败，请检查服务日志。'
        fi
        rc-service sshd status || die 'SSH 未处于运行状态。'
    else
        PIDFILE=$(printf '%s\n' "$EFFECTIVE" | awk '$1 == "pidfile" {print $2}')
        PID=''
        [ ! -f "$PIDFILE" ] || PID=$(cat "$PIDFILE")
        case "$PID" in ''|*[!0-9]*) PID='' ;; esac
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            [ "$(cat "/proc/$PID/comm")" = sshd ] || die 'PID 文件指向非 sshd 进程，拒绝重载。'
            kill -HUP "$PID"
            sleep 1
            kill -0 "$PID" 2>/dev/null || die 'SSH 重载后退出，请检查日志。'
        else
            "$SSHD" || die 'SSH 启动失败，请检查端口占用和日志。'
            sleep 1
            [ -f "$PIDFILE" ] || die '未找到 SSH PID 文件，请检查日志。'
            PID=$(cat "$PIDFILE")
            case "$PID" in ''|*[!0-9]*) die 'SSH PID 文件无效。' ;; esac
            kill -0 "$PID" 2>/dev/null || die 'SSH 启动后退出，请检查日志。'
        fi
        printf '[提示] 未检测到运行中的 OpenRC，仅处理当前服务；重建/重启容器后的启动需由容器配置保证。\n'
    fi
    printf '\nSSH 服务已启动或重载，用户名：root\n监听配置：\n'
    printf '%s\n' "$EFFECTIVE" | awk '$1 == "port" || $1 == "listenaddress"'
    printf '请从另一终端验证密码登录；外部访问还取决于容器端口映射、防火墙及其他 Match/AllowUsers 规则。\n'
}

install_singbox() {
    if ! command -v bash >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash curl ca-certificates
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update
            apt-get install -y bash curl ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y bash curl ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            yum install -y bash curl ca-certificates
        else
            die '请先安装 bash、curl 和 CA 证书。'
        fi
    fi
    URL=https://raw.githubusercontent.com/caigouzi121380/singbox-deploy/main/install-singbox-yyds.sh
    printf '下载并运行第三方 sing-box 安装脚本：%s\n' "$URL"
    DOWNLOAD=$(mktemp)
    trap 'rm -f "$DOWNLOAD"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    curl -fsSL "$URL" -o "$DOWNLOAD" || die '下载失败，未执行安装脚本。'
    [ -s "$DOWNLOAD" ] || die '下载内容为空。'
    bash -n "$DOWNLOAD" || die '安装脚本语法检查失败。'
    # Give the upstream interactive installer the terminal, not the script pipe.
    bash "$DOWNLOAD" <&3
}

[ "$(id -u)" -eq 0 ] || die '请使用 root 用户执行。'
if ! { exec 3</dev/tty; } 2>/dev/null; then
    die '需要交互终端，请在终端中运行（远程执行请使用 ssh -t）。'
fi
printf '\n=== Alpine SSH / sing-box ===\n1) 检测并配置 Alpine SSH\n2) 一键安装 sing-box\n0) 退出\n'
while :; do
    ask '请输入数字 [0/1/2]: '
    case "$REPLY" in
        1) setup_ssh; break ;;
        2) install_singbox; break ;;
        0) exit 0 ;;
        *) printf '无效选择，请输入 0、1 或 2。\n' ;;
    esac
done
