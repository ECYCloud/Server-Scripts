#!/usr/bin/env bash
# IP 被墙检测：定时检测国内目标的 IPv4 / IPv6 连通性，全部不通时调用接口更换 IP，使用说明见 README.md
set -euo pipefail

BIN=/usr/local/bin/check-ip
CONFIG_FILE=${CHECK_IP_CONFIG:-/etc/check-ip.conf}
UNIT_DIR=/etc/systemd/system
JOURNAL_CONF=/etc/systemd/journald@check-ip.conf
TCP_TIMEOUT=3
TCP_TRIES=3
# 调用更换接口后最多等待新 IP 生效的秒数，以及查询间隔
WAIT_SECONDS=180
WAIT_STEP=5
# 冷却状态目录：服务里由 StateDirectory= / ReadWritePaths= 放行，ProtectSystem=strict 下其它位置不可写
STATE_DIR=/var/lib/check-ip
# 配置行格式：KEY=VALUE，值可加双引号，行尾可加 # 注释；SKIP 为可忽略的空行与注释行
PAIR='^([A-Z0-9_]+)="?([^"#[:space:]]*)"?[[:space:]]*(#.*)?$'
SKIP='^[[:space:]]*(#|$)'
# 检测目标：IPv4 为「域名或 IPv4:端口」，IPv6 为「域名或 [IPv6]:端口」；域名标签不以 - 开头或结尾，IPv4 每段 0-255，端口 1-65535
OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
LABEL='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
PORT='([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])'
DOMAIN="($LABEL\.)+[A-Za-z]{2,63}"
TARGET4="($DOMAIN|$OCTET(\.$OCTET){3}):$PORT"
TARGET6="($DOMAIN|\[[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*\]):$PORT"
TARGETS4_RE="^$TARGET4(,$TARGET4)*$"
TARGETS6_RE="^$TARGET6(,$TARGET6)*$"
# 接口地址经 curl 配置的双引号传递，不允许双引号、反斜杠与 #；IPv6 的接口可留空
API_RE='^https?://[^"#\\]+$'
API6_RE='^(https?://[^"#\\]+)?$'
BOOL_RE='^(true|false)$'
RETRY_RE='^([1-9]|1[0-9]|20)$'
COOLDOWN_RE='^(0|[1-9][0-9]{0,2}|1[0-3][0-9]{2}|14[0-3][0-9]|1440)$'
INTERVAL_RE='^([1-9][0-9]{0,2}|1[0-3][0-9]{2}|14[0-3][0-9]|1440)$'

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "$*"; exit 1; }

# 配置模板，每项为「配置项|默认值|说明」；新装与更新都按它生成配置文件
TEMPLATE=(
    'CHECK_IPV4|true|是否检测 IPv4：true / false'
    'CHECK_TARGETS|douyin.com:443,mirrors.tuna.tsinghua.edu.cn:443|IPv4 检测目标「域名或 IPv4:TCP 端口」，多个用英文逗号分隔；任一目标的 TCP 端口可连接即判定正常'
    'CHANGE_IP_API||IPv4 不通时调用的更换 IP 接口（服务商提供），请求该地址即更换 IP'
    'CHECK_IPV6|false|是否检测 IPv6：true / false'
    'CHECK_TARGETS_V6|mirrors.tuna.tsinghua.edu.cn:443,mirrors.ustc.edu.cn:443|IPv6 检测目标「域名或 [IPv6]:TCP 端口」，多个用英文逗号分隔'
    'CHANGE_IPV6_API||IPv6 不通时调用的更换 IP 接口；留空则只记录、不更换，接口能同时换 IPv4 和 IPv6 时填与 CHANGE_IP_API 相同的地址'
    'MAX_RETRY|5|所有目标都不通时最多连续更换 IP 的次数（1-20），计数跨运行延续，IPv4 与 IPv6 分别计数'
    'COOLDOWN_MINUTES|60|换满次数仍不通或无法更换后，多少分钟内不再更换 IP（0-1440，0 表示不冷却）'
    'INTERVAL_MINUTES|1|执行间隔（分钟，1-1440），修改后执行 check-ip install 生效'
)

# 按模板输出配置文件内容，配置值取自 CFG_<配置项>
render_config() {
    local entry key default comment value
    for entry in "${TEMPLATE[@]}"; do
        IFS='|' read -r key default comment <<<"$entry"
        value=CFG_$key
        printf '%-22s # %s\n' "$key=${!value}" "$comment"
    done
}

# 读取配置到 CFG_<配置项>：先取模板默认值，配置文件存在时按白名单逐行覆盖；不 source 配置文件，避免执行其中的代码
# 无法识别的配置项记入 DROPPED
read_config() {
    local line key default comment entry keys=, n=0
    DROPPED=''
    for entry in "${TEMPLATE[@]}"; do
        IFS='|' read -r key default comment <<<"$entry"
        printf -v "CFG_$key" '%s' "$default"
        keys+="$key,"
    done
    [[ -e "$CONFIG_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ $SKIP ]] && continue
        # 报错只给行号，避免把接口地址打进日志
        [[ "$line" =~ $PAIR ]] || die "$CONFIG_FILE 第 $n 行格式错误，请修正后重新执行 check-ip install"
        key=${BASH_REMATCH[1]}
        if [[ "$keys" == *",$key,"* ]]; then
            printf -v "CFG_$key" '%s' "${BASH_REMATCH[2]}"
        else
            DROPPED+=" $key"
        fi
    done <"$CONFIG_FILE"
}

# 按模板写入配置文件；先写临时文件再替换，避免定时任务读到写了一半的配置，内容未变化时不改动文件
# mktemp 建的临时文件权限为 600，接口地址不会短暂暴露
write_config() {
    local tmp
    tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
    render_config >"$tmp"
    if [[ -e "$CONFIG_FILE" ]] && cmp -s "$tmp" "$CONFIG_FILE"; then
        rm -f "$tmp"
    else
        mv -f "$tmp" "$CONFIG_FILE"
        echo "配置已保存到 $CONFIG_FILE"
    fi
    chown root:root "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

# 缺少依赖时用系统包管理器安装
ensure_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=(curl)
    command -v flock >/dev/null || missing+=(util-linux)
    ((${#missing[@]})) || return 0
    echo "正在安装依赖：${missing[*]}"
    if command -v apt-get >/dev/null; then
        # 非交互安装，避免 Ubuntu 的 needrestart 弹出对话框等待选择
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq "${missing[@]}"
    elif command -v dnf >/dev/null; then
        dnf install -y -q "${missing[@]}"
    elif command -v yum >/dev/null; then
        yum install -y -q "${missing[@]}"
    else
        die "无法自动安装 ${missing[*]}，请手动安装后重新执行 check-ip install"
    fi
}

# 用法：ask 变量名 提示 校验正则；方括号内显示当前值，直接回车保留，输入 - 清空（只有允许留空的配置项能通过校验）
ask() {
    local var=$1 prompt=$2 re=$3 input cur=${!1}
    while true; do
        # 输入结束（Ctrl-D）时退出，否则当前值不合法时会无限重复提示
        read -rp "$prompt${cur:+ [$cur]}：" input || die "输入已结束，配置未保存"
        # 复制粘贴常带首尾空格，这些配置值本身不含空白，统一去掉
        input=${input//[[:space:]]/}
        if [[ "$input" == - ]]; then
            input=''
        else
            input=${input:-$cur}
        fi
        [[ "$input" =~ $re ]] && break
        echo "  格式不正确，请重新输入"
    done
    printf -v "$var" '%s' "$input"
}

# 用法：ask_yes_no 变量名 提示；变量值为 true / false，直接回车保留当前值
ask_yes_no() {
    local var=$1 input def=n hint=y/N
    if [[ "${!1}" == true ]]; then
        def=y hint=Y/n
    fi
    while true; do
        read -rp "$2 [$hint]：" input || die "输入已结束，配置未保存"
        input=${input//[[:space:]]/}
        case "${input:-$def}" in
            [Yy] | [Yy][Ee][Ss]) printf -v "$var" true; return ;;
            [Nn] | [Nn][Oo]) printf -v "$var" false; return ;;
        esac
        echo "  请输入 y 或 n"
    done
}

# 用法：get_ip 4|6；依次尝试多个境外查询源，输出通过格式校验的本机公网 IP
get_ip() {
    local ip url
    for url in https://api64.ipify.org https://icanhazip.com; do
        ip=$(curl -q -"$1" -sS --proto =https --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        if [[ "$1" == 4 && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" == 6 && "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

shown_ip() {
    get_ip "$1" || echo "获取失败"
}

# 交互式填写配置
configure() {
    local ip
    echo "按提示填写配置，方括号内为当前值，直接回车保留"
    # 新装时按本机实际网络给出 IPv4 / IPv6 的默认选项
    if [[ ! -e "$CONFIG_FILE" ]]; then
        if ip=$(get_ip 4); then echo "检测到本机公网 IPv4：$ip"; else CFG_CHECK_IPV4=false; echo "未检测到本机公网 IPv4"; fi
        if ip=$(get_ip 6); then CFG_CHECK_IPV6=true; echo "检测到本机公网 IPv6：$ip"; else echo "未检测到本机公网 IPv6"; fi
    fi
    while true; do
        ask_yes_no CFG_CHECK_IPV4 "是否检测 IPv4"
        ask_yes_no CFG_CHECK_IPV6 "是否检测 IPv6"
        [[ "$CFG_CHECK_IPV4" == false && "$CFG_CHECK_IPV6" == false ]] || break
        echo "  IPv4 和 IPv6 至少开启一个"
    done
    if [[ "$CFG_CHECK_IPV4" == true ]]; then
        ask CFG_CHECK_TARGETS "IPv4 检测目标（域名或 IPv4:TCP 端口，多个用英文逗号分隔）" "$TARGETS4_RE"
        ask CFG_CHANGE_IP_API "IPv4 不通时调用的更换 IP 接口" "$API_RE"
    fi
    if [[ "$CFG_CHECK_IPV6" == true ]]; then
        ask CFG_CHECK_TARGETS_V6 "IPv6 检测目标（域名或 [IPv6]:TCP 端口，多个用英文逗号分隔）" "$TARGETS6_RE"
        ask CFG_CHANGE_IPV6_API "IPv6 不通时调用的更换 IP 接口（留空则只记录、不更换，输入 - 清空）" "$API6_RE"
    fi
    ask CFG_MAX_RETRY "所有目标都不通时最多连续更换几次 IP（1-20）" "$RETRY_RE"
    ask CFG_COOLDOWN_MINUTES "换满次数仍不通后多少分钟内不再更换 IP（0-1440，0 表示不冷却）" "$COOLDOWN_RE"
    ask CFG_INTERVAL_MINUTES "每多少分钟检测一次（1-1440）" "$INTERVAL_RE"
}

install_self() {
    [[ $EUID -eq 0 ]] || die "install 需要 root 权限"
    local src interactive=false timer_active=false sd_version namespace='' log_cmd='journalctl -u check-ip -n 20 --no-pager'
    [[ -t 0 ]] && interactive=true
    ensure_deps
    src=$(realpath "${BASH_SOURCE[0]}")
    [[ "$src" == "$BIN" ]] || install -m 755 -o root -g root "$src" "$BIN"
    read_config
    [[ -z "$DROPPED" ]] || echo "已移除无法识别的配置项：${DROPPED# }"
    [[ "$interactive" == false ]] || configure
    [[ "$CFG_INTERVAL_MINUTES" =~ $INTERVAL_RE ]] || die "INTERVAL_MINUTES 只能是 1-1440 的整数，请修正 $CONFIG_FILE 后重新执行 check-ip install"
    write_config
    # 配置可能已修正，清除冷却与更换计数，使新配置立即生效；先停掉正在运行的检测，否则它会按旧配置继续更换并重新写入冷却
    # 定时器一起停：只停检测的话，定时器可能立刻把它重新拉起来抢锁；记下原状态，后面按原状态恢复
    systemctl is-active --quiet check-ip.timer && timer_active=true
    systemctl stop check-ip.timer check-ip.service 2>/dev/null || true
    # 手动运行或上次的试运行（SSH 断开后仍在后台）不受 systemctl 管理，加锁确认没有它们再清除
    # 目录只给 root 访问，否则普通用户也能打开它并一直占着锁，让检测永远跳过
    [[ -d "$STATE_DIR" ]] || mkdir -m 700 "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    exec 9<"$STATE_DIR"
    if ! flock -n 9; then
        [[ "$timer_active" == false ]] || systemctl start check-ip.timer
        die "另一个 check-ip 正在运行（可能是上次的试运行），配置已保存；请等它结束后重新执行 check-ip install"
    fi
    rm -f "$STATE_DIR"/cooldown-ipv[46] "$STATE_DIR"/attempts-ipv[46]
    # 释放锁，后面的试运行要用
    exec 9<&-
    # systemd 245 起支持日志命名空间：日志单独存放并限制总量，不影响服务器上其它服务的日志
    sd_version=$(systemctl --version | awk 'NR == 1 {print $2}')
    if [[ "$sd_version" =~ ^[0-9]+$ ]] && ((sd_version >= 245)); then
        namespace='LogNamespace=check-ip'
        log_cmd='journalctl --namespace=check-ip -n 20 --no-pager'
        printf '[Journal]\nSystemMaxUse=10M\nRuntimeMaxUse=10M\n' >"$JOURNAL_CONF"
    else
        echo "当前 systemd 版本低于 245，无法单独限制日志大小，日志写入系统日志"
    fi
    cat >"$UNIT_DIR/check-ip.service" <<EOF
[Unit]
Description=VPS IP block check
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
StateDirectory=check-ip
StateDirectoryMode=0700
# 低于 235 的 systemd 不支持 StateDirectory=，状态目录由 install 预先创建并在这里放行写入
ReadWritePaths=-$STATE_DIR
# 等待新 IP 生效时一次运行会持续数分钟，显式关闭启动超时
TimeoutStartSec=infinity
# 标记由定时任务启动，遇到手动运行或试运行时直接跳过
Environment=CHECK_IP_TIMER=1
# 脚本输出记为 notice，并丢弃 systemd 每次启停写的 info 记录；运行失败的 warning 仍保留
SyslogLevel=notice
LogLevelMax=notice
$namespace
EOF
    cat >"$UNIT_DIR/check-ip.timer" <<EOF
[Unit]
Description=Run VPS IP block check every $CFG_INTERVAL_MINUTES minute(s)

[Timer]
# 不用 OnBootSec：开机时间已过时启动定时器会立即触发，首次安装试运行后会紧接着再检测一轮
# 重装时若距上次运行已超过间隔，OnUnitActiveSec 仍会立即触发一次，由单实例锁避免与试运行同时更换
OnActiveSec=${CFG_INTERVAL_MINUTES}min
OnUnitActiveSec=${CFG_INTERVAL_MINUTES}min
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    # 日志实例已在运行时重启它，使新的大小限制生效
    [[ -z "$namespace" ]] || systemctl try-restart systemd-journald@check-ip.service
    if [[ "$interactive" == false ]]; then
        # 定时任务原来在运行时重新启动它，使新的执行间隔生效
        [[ "$timer_active" == false ]] || systemctl restart check-ip.timer
        echo "已按现有配置安装。在终端中执行 check-ip install 可按提示修改配置并启用定时任务"
        return 0
    fi
    # 先启用定时任务再试运行：试运行若换了 IP，SSH 会断开，install 可能来不及执行后面的命令
    systemctl enable --quiet check-ip.timer
    systemctl restart check-ip.timer
    echo "定时任务已启用：每 $CFG_INTERVAL_MINUTES 分钟自动执行一次。查看日志：$log_cmd"
    echo "正在试运行……"
    # 忽略 SSH 断开时的挂断信号，让试运行跑完；试运行失败只表示当前网络有问题
    trap '' HUP
    "$BIN" || echo "试运行未全部通过（原因见上方），定时任务会按间隔继续检测"
}

load_config() {
    read_config
    [[ -z "$DROPPED" ]] || die "$CONFIG_FILE 中有未知配置项：${DROPPED# }"
    [[ "$CFG_CHECK_IPV4" =~ $BOOL_RE && "$CFG_CHECK_IPV6" =~ $BOOL_RE ]] || die "CHECK_IPV4、CHECK_IPV6 只能是 true 或 false"
    [[ "$CFG_CHECK_IPV4" == true || "$CFG_CHECK_IPV6" == true ]] || die "CHECK_IPV4 与 CHECK_IPV6 不能同时为 false"
    if [[ "$CFG_CHECK_IPV4" == true ]]; then
        [[ "$CFG_CHECK_TARGETS" =~ $TARGETS4_RE ]] || die "CHECK_TARGETS 未填写或格式不正确"
        [[ "$CFG_CHANGE_IP_API" =~ $API_RE ]] || die "CHANGE_IP_API 未填写或格式不正确"
    fi
    if [[ "$CFG_CHECK_IPV6" == true ]]; then
        [[ "$CFG_CHECK_TARGETS_V6" =~ $TARGETS6_RE ]] || die "CHECK_TARGETS_V6 未填写或格式不正确"
        [[ "$CFG_CHANGE_IPV6_API" =~ $API6_RE ]] || die "CHANGE_IPV6_API 格式不正确"
    fi
    [[ "$CFG_MAX_RETRY" =~ $RETRY_RE ]] || die "MAX_RETRY 只能是 1-20 的整数"
    [[ "$CFG_COOLDOWN_MINUTES" =~ $COOLDOWN_RE ]] || die "COOLDOWN_MINUTES 只能是 0-1440 的整数"
}

# 用法：is_reachable 4|6；任一目标的 TCP 端口可连接返回 0，全部不通返回 1，全部解析不到对应地址返回 2
# 逐项结果只在终端手动运行时显示
is_reachable() {
    local fam=$1 target host port ip try resolved=0 targets=()
    if [[ "$fam" == 4 ]]; then
        IFS=, read -ra targets <<<"$CFG_CHECK_TARGETS"
    else
        IFS=, read -ra targets <<<"$CFG_CHECK_TARGETS_V6"
    fi
    for target in "${targets[@]}"; do
        host=${target%:*} port=${target##*:}
        host=${host#\[} host=${host%\]}
        # 先解析出对应协议的地址再检测，避免连接走另一个协议；ahostsv6 带 AI_V4MAPPED，要排除 ::ffff: 开头的 IPv4 映射地址
        ip=$(getent "ahostsv$fam" "$host" | awk '$1 !~ /^::ffff:/ {print $1; exit}') || true
        # 域名解析失败是本机 DNS 的问题，不能当作被墙
        if [[ -z "$ip" ]]; then
            [[ ! -t 2 ]] || log "IPv$fam ${host}：解析不到 IPv$fam 地址，跳过"
            continue
        fi
        resolved=1
        # 以 TCP 连接为准：ICMP 放行而 TCP 被阻断时 ping 仍能通，不能用来判断；多试几次，避免偶发丢包误判
        for ((try = 1; try <= TCP_TRIES; try++)); do
            # --foreground：在终端运行时按 Ctrl-C 能中止，否则 timeout 自成进程组收不到中断，脚本会继续去换 IP
            if timeout --foreground "$TCP_TIMEOUT" bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
                [[ ! -t 2 ]] || log "IPv$fam ${host}：TCP $port 端口可连接，网络正常"
                return 0
            fi
        done
        [[ ! -t 2 ]] || log "IPv$fam ${host}：TCP $port 端口连续 ${TCP_TRIES} 次连接失败"
    done
    ((resolved)) || return 2
    return 1
}

# 用法：change_ip 接口地址；返回 curl 的退出码
change_ip() {
    local resp rc=0
    # 接口地址经标准输入交给 curl，不出现在进程参数和日志里（地址中可能带密钥）
    # -q 不读 ~/.curlrc，-g 不展开地址里的 {} []（否则一次调用会变成多次请求）；跟随跳转（如 http 跳到 https）
    # 连不上或返回 HTTP 错误时 curl 失败，记录其错误信息
    resp=$(printf 'url = "%s"\n' "$1" | curl -q -g -sSfL --connect-timeout 10 --max-time 15 -K - 2>&1) || rc=$?
    if ((rc == 0)); then
        log "已调用更换 IP 接口，返回：$resp"
    else
        log "调用更换 IP 接口失败：$resp"
    fi
    return "$rc"
}

# 用法：wait_ip_change 4|6 旧IP；本机公网 IP 变得与旧 IP 不同时输出新 IP 并返回 0，超过 WAIT_SECONDS 返回 1
# 服务商换 IP 常要几十秒，固定等几秒就重新检测会在旧 IP 上误判，接着又换
wait_ip_change() {
    local end=$((SECONDS + WAIT_SECONDS)) ip
    while ((SECONDS < end)); do
        sleep "$WAIT_STEP"
        if ip=$(get_ip "$1") && [[ "$ip" != "$2" ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 用法：cooldown_left 4|6；冷却中时输出剩余分钟数并返回 0
cooldown_left() {
    local end_at now
    end_at=$(cat "$STATE_DIR/cooldown-ipv$1" 2>/dev/null) || return 1
    now=$(date +%s)
    if [[ "$end_at" =~ ^[0-9]+$ ]] && ((end_at > now)); then
        echo $(((end_at - now + 59) / 60))
        return 0
    fi
    return 1
}

# 用法：stop_changing 4|6 原因；记录原因并结束本轮更换，冷却时长大于 0 时开始冷却，冷却期内只检测、不更换
stop_changing() {
    # 本轮已结束，清除更换计数；否则不冷却时下次运行一开始就已达上限，再也不会更换
    rm -f "$STATE_DIR/attempts-ipv$1"
    if ((CFG_COOLDOWN_MINUTES == 0)); then
        log "IPv$1：$2"
    elif echo $(($(date +%s) + CFG_COOLDOWN_MINUTES * 60)) >"$STATE_DIR/cooldown-ipv$1"; then
        log "IPv$1：$2，${CFG_COOLDOWN_MINUTES} 分钟内不再更换 IP"
    else
        log "IPv$1：$2；冷却状态写入失败，下次运行可能继续更换"
    fi
}

# 用法：check_family 4|6；网络正常、更换后恢复或冷却中返回 0
check_family() {
    local fam=$1 retry st rc left cur old new api=$CFG_CHANGE_IP_API attempts=$STATE_DIR/attempts-ipv$1
    [[ "$fam" == 4 ]] || api=$CFG_CHANGE_IPV6_API
    # 连境外查询源都访问不到时，说明本机没有该协议的外网连接，不能当作被墙
    cur=$(get_ip "$fam") || { log "IPv$fam：获取本机公网 IPv$fam 失败，本次跳过检测"; return 1; }
    # 更换次数存在状态文件里：换 IP 让服务器重启或运行被中断时，下次运行接着计数，不会从 0 开始无限更换
    retry=$(cat "$attempts" 2>/dev/null) || retry=0
    [[ "$retry" =~ ^[0-9]+$ ]] || retry=0
    # 每次更换后都重新检测，最后一次换出的 IP 也会被验证
    while true; do
        if is_reachable "$fam"; then break; else st=$?; fi
        ((st == 1)) || { log "IPv$fam：所有检测目标都解析不到 IPv$fam 地址，无法判断是否被墙，本次不更换 IP"; return 1; }
        # 冷却期内不更换；进入冷却时已记录原因，这里只在终端显示，避免每次运行都写日志
        if left=$(cooldown_left "$fam"); then
            [[ ! -t 2 ]] || log "IPv$fam：所有检测目标均不通，冷却中，${left} 分钟内不更换 IP"
            return 0
        fi
        # 只有 IPv6 的接口允许留空：不借用 IPv4 接口，避免 IPv6 被墙时把 IPv4 无故换掉
        if [[ -z "$api" ]]; then
            stop_changing "$fam" "当前 IP $(shown_ip "$fam")：所有检测目标均不通，未填写 CHANGE_IPV6_API，无法更换"
            return 1
        fi
        if ((retry >= CFG_MAX_RETRY)); then
            stop_changing "$fam" "当前 IP $(shown_ip "$fam")：已尝试更换 ${retry} 次仍无法连通任何检测目标，请人工排查"
            return 1
        fi
        retry=$((retry + 1))
        echo "$retry" >"$attempts"
        # 查询偶发失败时沿用上次取到的 IP，否则等待时第一次查询成功就会被当成 IP 已变化
        old=$(get_ip "$fam") || old=$cur
        log "IPv$fam：当前 IP ${old}：所有检测目标均不通，第 ${retry} 次更换 IP"
        if change_ip "$api"; then rc=0; else rc=$?; fi
        case "$rc" in
            0)
                if new=$(wait_ip_change "$fam" "$old"); then
                    cur=$new
                else
                    stop_changing "$fam" "调用更换接口后 ${WAIT_SECONDS} 秒内 IP 仍未变化"
                    return 1
                fi
                ;;
            16 | 18 | 28 | 52 | 56 | 92)
                # HTTP/2 出错、传输不完整、超时、空响应或接收中断：请求可能已送达，服务商可能正在更换，等 IP 变化后再判断，避免接连再换
                # curl 对连接超时和响应超时都返回 28，无法区分，连接超时也会等待
                log "IPv$fam：请求可能已送达，等待 IP 变化"
                if new=$(wait_ip_change "$fam" "$old"); then cur=$new; fi
                ;;
            # 其它失败（连接被拒绝、解析失败、返回 HTTP 错误等）IP 不会变化，不必等待，直接计入次数
        esac
    done
    rm -f "$STATE_DIR/cooldown-ipv$fam" "$attempts"
    ((retry == 0)) || log "IPv$fam：更换后网络恢复，当前 IP $(shown_ip "$fam")"
}

main() {
    local rc=0 fam enabled
    case "${1:-}" in
        install) install_self; return ;;
        "") ;;
        *) die "用法：check-ip [install]" ;;
    esac
    command -v curl >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null && command -v getent >/dev/null || die "缺少依赖：需要 curl、flock、timeout 与 getent"
    [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "无法读取 ${CONFIG_FILE}：请以 root 运行，尚未安装时先执行 install"
    # 以状态目录加锁：同时只运行一个实例，避免手动运行与定时任务同时更换 IP
    # 不锁配置文件：编辑器保存时可能替换文件，新旧实例会各锁一个文件而同时运行；目录只给 root 访问，见 install_self
    [[ -d "$STATE_DIR" ]] || mkdir -m 700 "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    exec 9<"$STATE_DIR"
    if [[ -n "${CHECK_IP_TIMER:-}" ]]; then
        # 定时任务遇到手动运行或试运行时直接跳过，不排队等锁，避免反复超时报错
        flock -n 9 || exit 0
    else
        flock -w 300 9 || die "等待另一个 check-ip 结束超过 300 秒，本次退出"
    fi
    load_config
    for fam in 4 6; do
        enabled=CFG_CHECK_IPV$fam
        [[ "${!enabled}" == true ]] || continue
        check_family "$fam" || rc=1
    done
    return "$rc"
}

# 主流程放在函数内且与 exit 同行：bash 执行前已读完整个流程，运行中脚本文件被更新覆盖也不受影响
main "$@"; exit $?
