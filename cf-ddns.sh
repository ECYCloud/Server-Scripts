#!/usr/bin/env bash
# Cloudflare DDNS：把本机公网 IPv4 / IPv6 同步到 Cloudflare 的 A / AAAA 记录，使用说明见 README.md
set -euo pipefail

BIN=/usr/local/bin/cf-ddns
CONFIG_FILE=${CF_DDNS_CONFIG:-/etc/cf-ddns.conf}
UNIT_DIR=/etc/systemd/system
JOURNAL_CONF=/etc/systemd/journald@cf-ddns.conf
# 配置行格式：KEY=VALUE，值可加双引号，行尾可加 # 注释；SKIP 为可忽略的空行与注释行
PAIR='^([A-Z0-9_]+)="?([^"#[:space:]]*)"?[[:space:]]*(#.*)?$'
SKIP='^[[:space:]]*(#|$)'
TOKEN_RE='^[A-Za-z0-9_-]{20,}$'
ZONE_RE='^[a-f0-9]{32}$'
DOMAIN_RE='^([a-z0-9_-]{1,63}\.)+[a-z0-9-]{2,63}$'
INTERVAL_RE='^([1-9][0-9]{0,2}|1[0-3][0-9]{2}|14[0-3][0-9]|1440)$'

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "$*"; exit 1; }

# 配置模板，每项为「配置项|默认值|说明」；新装与更新都按它生成配置文件
TEMPLATE=(
    'CF_API_TOKEN||Cloudflare API 令牌，用「编辑区域 DNS」模板创建'
    'CF_ZONE_ID||域名概述页右侧 API 区域里的区域 ID（32 位）'
    'CF_RECORDS||域名:是否开启代理，多个用英文逗号分隔，例如 1.example.com:true,2.example.com:false'
    'ENABLE_IPV4|true|是否更新 A 记录：true / false'
    'ENABLE_IPV6|true|是否更新 AAAA 记录：true / false'
    'CF_TTL|1|新建未开代理记录的 TTL（秒），1 表示自动；已有记录不改'
    'INTERVAL_MINUTES|1|执行间隔（分钟，1-1440），修改后执行 cf-ddns install 生效'
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

# 读取已有配置的值到 CFG_<配置项>
read_config() {
    local line key entry keys=, dropped='' n=0
    for entry in "${TEMPLATE[@]}"; do
        keys+="${entry%%|*},"
    done
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ $SKIP ]] && continue
        # 读不出值的行不能丢弃，否则会丢失配置值
        [[ "$line" =~ $PAIR ]] || die "$CONFIG_FILE 第 $n 行格式错误，配置文件未改动；请修正后重新执行 cf-ddns install"
        key=${BASH_REMATCH[1]}
        if [[ "$keys" == *",$key,"* ]]; then
            printf -v "CFG_$key" '%s' "${BASH_REMATCH[2]}"
        else
            dropped+=" $key"
        fi
    done <"$CONFIG_FILE"
    [[ -z "$dropped" ]] || echo "已移除无法识别的配置项：${dropped# }"
}

# 按模板写入配置文件；先写临时文件再替换，避免定时任务读到写了一半的配置，内容未变化时不改动文件
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
    command -v jq >/dev/null || missing+=(jq)
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
        die "无法自动安装 ${missing[*]}，请手动安装后重新执行 cf-ddns install"
    fi
}

# 用法：ask 变量名 提示 校验正则 [masked]；方括号内显示当前值，直接回车保留，masked 时当前值只显示末 4 位
ask() {
    local var=$1 prompt=$2 re=$3 input cur=${!1} shown=${!1}
    [[ "${4:-}" != masked || -z "$cur" ]] || shown="****${cur: -4}"
    while true; do
        read -rp "$prompt${shown:+ [$shown]}：" input
        # 复制粘贴常带首尾空格，这些配置值本身不含空白，统一去掉
        input=${input//[[:space:]]/}
        input=${input:-$cur}
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
        read -rp "$2 [$hint]：" input
        input=${input//[[:space:]]/}
        case "${input:-$def}" in
            [Yy] | [Yy][Ee][Ss]) printf -v "$var" true; return ;;
            [Nn] | [Nn][Oo]) printf -v "$var" false; return ;;
        esac
        echo "  请输入 y 或 n"
    done
}

# 设置域名列表，结果写入 CFG_CF_RECORDS：已有域名逐个确认保留与代理开关，再输入新增域名
ask_records() {
    local item name proxied list='' change=false keep items=()
    IFS=, read -ra items <<<"$(tr '[:upper:]' '[:lower:]' <<<"$CFG_CF_RECORDS")"
    if ((${#items[@]})); then
        echo "当前域名："
        for item in "${items[@]}"; do
            [[ -z "$item" ]] || echo "  ${item%%:*}（代理$([[ "${item##*:}" == true ]] && echo 开启 || echo 关闭)）"
        done
        ask_yes_no change "是否修改域名（增删域名或调整代理）"
        [[ "$change" == true ]] || return 0
        echo "逐个确认现有域名，直接回车保持原设置"
        for item in "${items[@]}"; do
            name=${item%%:*}
            [[ -n "$name" ]] || continue
            if [[ ! "$name" =~ $DOMAIN_RE ]]; then
                echo "  已移除格式不正确的域名：$name"
                continue
            fi
            keep=true
            ask_yes_no keep "保留 $name"
            [[ "$keep" == true ]] || continue
            [[ "${item##*:}" == true ]] && proxied=true || proxied=false
            ask_yes_no proxied "  $name 是否开启 Cloudflare 代理（开启后只能用于网页服务）"
            [[ ",$list," == *",$name:"* ]] || list+="${list:+,}$name:$proxied"
        done
        echo "输入要新增的域名，没有或输入完后直接回车"
    else
        echo "逐个输入要自动更新的域名，全部输入完后直接回车"
    fi
    while true; do
        read -rp "域名：" name
        name=$(tr '[:upper:]' '[:lower:]' <<<"${name//[[:space:]]/}")
        if [[ -z "$name" ]]; then
            [[ -z "$list" ]] || break
            echo "  至少需要一个域名，请输入"
        elif [[ ! "$name" =~ $DOMAIN_RE ]]; then
            echo "  域名格式不正确，例如 ddns.example.com"
        elif [[ ",$list," == *",$name:"* ]]; then
            echo "  该域名已在列表中"
        else
            proxied=false
            ask_yes_no proxied "  $name 是否开启 Cloudflare 代理（开启后只能用于网页服务）"
            list+="${list:+,}$name:$proxied"
        fi
    done
    CFG_CF_RECORDS=$list
}

# 交互式填写配置
configure() {
    local ip
    echo "按提示填写配置，方括号内为当前值，直接回车保留"
    ask CFG_CF_API_TOKEN "Cloudflare API 令牌" "$TOKEN_RE" masked
    ask CFG_CF_ZONE_ID "区域 ID" "$ZONE_RE"
    ask_records
    # 新装时按本机实际网络给出 IPv4 / IPv6 的默认选项
    if [[ ! -e "$CONFIG_FILE" ]]; then
        if ip=$(get_ip 4); then echo "检测到本机公网 IPv4：$ip"; else CFG_ENABLE_IPV4=false; echo "未检测到本机公网 IPv4"; fi
        if ip=$(get_ip 6); then echo "检测到本机公网 IPv6：$ip"; else CFG_ENABLE_IPV6=false; echo "未检测到本机公网 IPv6"; fi
    fi
    while true; do
        ask_yes_no CFG_ENABLE_IPV4 "是否更新 IPv4（A 记录）"
        ask_yes_no CFG_ENABLE_IPV6 "是否更新 IPv6（AAAA 记录）"
        [[ "$CFG_ENABLE_IPV4" == false && "$CFG_ENABLE_IPV6" == false ]] || break
        echo "  IPv4 和 IPv6 至少开启一个"
    done
    ask CFG_INTERVAL_MINUTES "每多少分钟执行一次（1-1440）" "$INTERVAL_RE"
}

install_self() {
    [[ $EUID -eq 0 ]] || die "install 需要 root 权限"
    local src entry key default comment interactive=false sd_version namespace='' log_cmd='journalctl -u cf-ddns -n 20 --no-pager'
    [[ -t 0 ]] && interactive=true
    ensure_deps
    src=$(realpath "${BASH_SOURCE[0]}")
    [[ "$src" == "$BIN" ]] || install -m 755 -o root -g root "$src" "$BIN"
    for entry in "${TEMPLATE[@]}"; do
        IFS='|' read -r key default comment <<<"$entry"
        printf -v "CFG_$key" '%s' "$default"
    done
    [[ ! -e "$CONFIG_FILE" ]] || read_config
    [[ "$interactive" == false ]] || configure
    [[ "$CFG_INTERVAL_MINUTES" =~ $INTERVAL_RE ]] || die "INTERVAL_MINUTES 只能是 1-1440 的整数，请修正 $CONFIG_FILE 后重新执行 cf-ddns install"
    write_config
    # systemd 245 起支持日志命名空间：DDNS 日志单独存放并限制总量，不影响服务器上其它服务的日志
    sd_version=$(systemctl --version | awk 'NR == 1 {print $2}')
    if [[ "$sd_version" =~ ^[0-9]+$ ]] && ((sd_version >= 245)); then
        namespace='LogNamespace=cf-ddns'
        log_cmd='journalctl --namespace=cf-ddns -n 20 --no-pager'
        printf '[Journal]\nSystemMaxUse=10M\nRuntimeMaxUse=10M\n' >"$JOURNAL_CONF"
    else
        echo "当前 systemd 版本低于 245，无法单独限制 DDNS 日志大小，日志写入系统日志"
    fi
    cat >"$UNIT_DIR/cf-ddns.service" <<EOF
[Unit]
Description=Cloudflare DDNS
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
# 脚本输出记为 notice，并丢弃 systemd 每次启停写的 info 记录；运行失败的 warning 仍保留
SyslogLevel=notice
LogLevelMax=notice
$namespace
EOF
    cat >"$UNIT_DIR/cf-ddns.timer" <<EOF
[Unit]
Description=Run Cloudflare DDNS every $CFG_INTERVAL_MINUTES minute(s)

[Timer]
OnBootSec=1min
OnUnitActiveSec=${CFG_INTERVAL_MINUTES}min
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    # 日志实例已在运行时重启它，使新的大小限制生效
    [[ -z "$namespace" ]] || systemctl try-restart systemd-journald@cf-ddns.service
    if [[ "$interactive" == false ]]; then
        # 定时任务已启用时重启它，使新的执行间隔立即生效
        systemctl try-restart cf-ddns.timer
        echo "已按现有配置安装。在终端中执行 cf-ddns install 可按提示修改配置并启用定时任务"
        return 0
    fi
    echo "正在试运行……"
    if ! "$BIN"; then
        echo "试运行失败，定时任务未启用。请根据上面的提示检查后重新执行 cf-ddns install"
        return 1
    fi
    systemctl enable --quiet cf-ddns.timer
    systemctl restart cf-ddns.timer
    echo "部署完成：每 $CFG_INTERVAL_MINUTES 分钟自动执行一次。查看日志：$log_cmd"
}

# 按白名单逐行读取 KEY=VALUE（允许行尾 # 注释），不 source 配置文件，避免执行其中的代码
load_config() {
    local line key item items seen=, n=0
    CF_API_TOKEN='' CF_ZONE_ID='' CF_RECORDS='' ENABLE_IPV4='' ENABLE_IPV6='' CF_TTL='' RECORDS=()
    [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" ]] || die "无法读取 ${CONFIG_FILE}：请以 root 运行，尚未安装时先执行 install"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ "$line" =~ $SKIP ]] && continue
        # 报错只给行号，避免把 Token 打进日志
        [[ "$line" =~ $PAIR ]] || die "$CONFIG_FILE 第 $n 行格式错误"
        key=${BASH_REMATCH[1]}
        case "$key" in
            CF_API_TOKEN | CF_ZONE_ID | CF_RECORDS | ENABLE_IPV4 | ENABLE_IPV6 | CF_TTL) printf -v "$key" '%s' "${BASH_REMATCH[2]}" ;;
            INTERVAL_MINUTES) ;; # 只由 install 写入定时器，运行时不需要
            *) die "$CONFIG_FILE 第 $n 行：未知配置项 $key" ;;
        esac
    done <"$CONFIG_FILE"
    [[ "$CF_API_TOKEN" =~ $TOKEN_RE ]] || die "CF_API_TOKEN 未填写或格式不正确"
    [[ "$CF_ZONE_ID" =~ $ZONE_RE ]] || die "CF_ZONE_ID 未填写或格式不正确"
    # RECORDS 条目格式：域名:是否开启代理；Cloudflare 的域名不区分大小写，统一转小写后再查重
    IFS=, read -ra items <<<"$(tr '[:upper:]' '[:lower:]' <<<"$CF_RECORDS")"
    for item in ${items[@]+"${items[@]}"}; do
        [[ "$item" =~ ^([^:]*):(true|false)$ && "${BASH_REMATCH[1]}" =~ $DOMAIN_RE ]] ||
            die "CF_RECORDS 中的「${item}」格式不正确，应为 域名:true 或 域名:false"
        [[ "$seen" != *",${item%:*},"* ]] || die "CF_RECORDS 中的 ${item%:*} 重复"
        seen+="${item%:*},"
        RECORDS+=("$item")
    done
    ((${#RECORDS[@]})) || die "CF_RECORDS 未填写"
    [[ "$ENABLE_IPV4" =~ ^(true|false)$ && "$ENABLE_IPV6" =~ ^(true|false)$ ]] || die "ENABLE_IPV4、ENABLE_IPV6 只能是 true 或 false"
    [[ "$ENABLE_IPV4" == true || "$ENABLE_IPV6" == true ]] || die "ENABLE_IPV4 与 ENABLE_IPV6 不能同时为 false"
    [[ "$CF_TTL" == 1 || ("$CF_TTL" =~ ^[1-9][0-9]{1,4}$ && "$CF_TTL" -ge 60 && "$CF_TTL" -le 86400) ]] || die "CF_TTL 只能是 1 或 60-86400"
}

# 用法：cf_api 方法 路径后缀 [JSON 请求体]；成功时输出响应 JSON
cf_api() {
    local resp args=(-sS --proto =https --max-time 15 -X "$1" -H "Content-Type: application/json" -K -)
    if [[ -n "${3:-}" ]]; then
        args+=(--data "$3")
    fi
    # Token 经标准输入交给 curl，不出现在进程参数里，其它本机用户用 ps 看不到
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" | curl "${args[@]}" "$API$2") || return 1
    if [[ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != true ]]; then
        log "Cloudflare API 返回失败：$(jq -c '.errors' <<<"$resp" 2>/dev/null || echo '响应不是 JSON')"
        return 1
    fi
    printf '%s' "$resp"
}

# 用法：get_ip 4|6；依次尝试多个查询源，输出通过格式校验的公网 IP
get_ip() {
    local ip url
    for url in https://api64.ipify.org https://icanhazip.com; do
        ip=$(curl -"$1" -sS --proto =https --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]') || continue
        if [[ "$1" == 4 && "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$1" == 6 && "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# 用法：sync_record A|AAAA IP 域名 true|false
sync_record() {
    local type=$1 ip=$2 name=$3 proxied=$4 resp count id current current_proxied body change=''
    resp=$(cf_api GET "?type=$type&name.exact=$name") || return 1
    count=$(jq '.result | length' <<<"$resp")
    case "$count" in
        0)
            # 开启代理的记录 TTL 固定为自动
            body=$(jq -nc --arg t "$type" --arg n "$name" --arg c "$ip" --argjson ttl "$CF_TTL" --argjson p "$proxied" \
                '{type: $t, name: $n, content: $c, ttl: (if $p then 1 else $ttl end), proxied: $p}')
            cf_api POST "" "$body" >/dev/null || return 1
            log "${type}：$name 已创建（IP ${ip}，代理 ${proxied}）"
            ;;
        1)
            id=$(jq -r '.result[0].id' <<<"$resp")
            current=$(jq -r '.result[0].content' <<<"$resp")
            current_proxied=$(jq -r '.result[0].proxied' <<<"$resp")
            [[ "$id" =~ ^[a-f0-9]{32}$ ]] || { log "${type}：$name 记录 ID 格式异常"; return 1; }
            [[ "$current" == "$ip" ]] || change="IP $current -> $ip"
            [[ "$current_proxied" == "$proxied" ]] || change+="${change:+，}代理 $current_proxied -> $proxied"
            if [[ -z "$change" ]]; then
                # 未变化只在终端手动运行时显示，定时任务不写入日志
                [[ ! -t 2 ]] || log "${type}：$name 未变化（IP ${ip}，代理 ${proxied}）"
                return 0
            fi
            # 只改 IP 与代理状态，保留记录现有的 TTL
            cf_api PATCH "/$id" "$(jq -nc --arg c "$ip" --argjson p "$proxied" '{content: $c, proxied: $p}')" >/dev/null || return 1
            log "${type}：$name 已更新（${change}）"
            ;;
        *)
            log "${type}：$name 存在 $count 条记录，请在 Cloudflare 只保留一条"
            return 1
            ;;
    esac
}

main() {
    local rc=0 family type version enabled ip item name proxied
    case "${1:-}" in
        install) install_self; return ;;
        "") ;;
        *) die "用法：cf-ddns [install]" ;;
    esac
    command -v curl >/dev/null && command -v jq >/dev/null && command -v flock >/dev/null || die "缺少依赖：需要 curl、jq 与 flock"
    load_config
    # 以配置文件加锁：同一份配置同时只运行一个实例，避免手动运行与定时任务重复创建记录
    exec 9<"$CONFIG_FILE"
    flock -w 120 9 || die "另一个 cf-ddns 运行超过 120 秒仍未结束，本次退出"
    API="https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records"

    for family in A:4 AAAA:6; do
        type=${family%:*} version=${family#*:}
        enabled=ENABLE_IPV$version
        [[ "${!enabled}" == true ]] || continue
        if ! ip=$(get_ip "$version"); then
            log "${type}：获取公网 IPv$version 失败"
            rc=1
            continue
        fi
        for item in "${RECORDS[@]}"; do
            IFS=: read -r name proxied <<<"$item"
            sync_record "$type" "$ip" "$name" "$proxied" || { log "${type}：$name 同步失败"; rc=1; }
        done
    done
    return "$rc"
}

# 主流程放在函数内且与 exit 同行：bash 执行前已读完整个流程，运行中脚本文件被更新覆盖也不受影响
main "$@"; exit $?
