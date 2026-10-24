# Server Scripts

服务器运维脚本，均以 systemd 定时任务运行，安装、配置与日志方式一致。

| 脚本 | 用途 |
| ---- | ---- |
| [Cloudflare DDNS](#cloudflare-ddns)（`cf-ddns.sh`） | 将服务器公网 IPv4 / IPv6 同步到 Cloudflare 的 A / AAAA 记录 |
| [IP 被墙检测](#ip-被墙检测)（`check-ip.sh`） | 检测服务器能否连通国内，全部不通时调用接口更换 IP |

## Cloudflare DDNS

将服务器当前的公网 IPv4 / IPv6 自动同步到 Cloudflare 的 A / AAAA 记录，支持多个域名，每个域名可单独设置是否开启代理。

### 准备

- 使用 systemd 的 Linux 服务器，以 root 执行命令（sudo 用户先执行 `sudo -i`）
- Cloudflare API 令牌：「我的个人资料 → API 令牌 → 创建令牌 → 编辑区域 DNS」，区域资源只选目标域名，不要设置客户端 IP 筛选
- 区域 ID：域名「概述」页右侧 API 区域

### 安装

```bash
curl -fsSL -o /usr/local/bin/cf-ddns https://raw.githubusercontent.com/ECYCloud/Server-Scripts/main/cf-ddns.sh && chmod 755 /usr/local/bin/cf-ddns && cf-ddns install
```

按提示依次填写：

1. Cloudflare API 令牌
2. 区域 ID
3. 域名：逐个输入，每个域名选择是否开启代理，全部输入完后直接回车
4. 是否更新 IPv4 / IPv6（默认值按本机检测结果给出）
5. 每多少分钟执行一次

填完后自动试运行，成功即启用定时任务。缺少 jq 等依赖时会自动安装；服务器没有 curl 时先执行 `apt-get install -y curl` 或 `dnf install -y curl`。

### 修改配置

```bash
cf-ddns install
```

按提示修改，方括号内为当前值，直接回车保留。修改域名时选择 `y`，现有域名会逐个确认是否保留、是否开启代理，之后可继续输入新增的域名。

### 更新

重新执行「安装」中的命令，已有配置作为默认值，一路回车即可保留。旧版配置中的 `CF_RECORD_NAME` / `CF_PROXIED` 会自动并入新的域名列表，代理状态沿用 Cloudflare 上的当前设置。

### 常用命令

| 操作 | 命令 |
| ---- | ---- |
| 查看最近日志 | `journalctl --namespace=cf-ddns -n 20 --no-pager`（systemd 低于 245 时用 `journalctl -u cf-ddns -n 20 --no-pager`） |
| 查看下次执行时间 | `systemctl list-timers cf-ddns.timer` |
| 立即执行一次 | `systemctl start cf-ddns.service` |

### 卸载

```bash
systemctl disable --now cf-ddns.timer
systemctl stop systemd-journald@cf-ddns.service
rm -f /usr/local/bin/cf-ddns /etc/cf-ddns.conf /etc/systemd/system/cf-ddns.service /etc/systemd/system/cf-ddns.timer /etc/systemd/journald@cf-ddns.conf
rm -rf /etc/systemd/system/cf-ddns.timer.d "/var/log/journal/$(cat /etc/machine-id).cf-ddns"
systemctl daemon-reload
```

### 说明

- 配置保存在 `/etc/cf-ddns.conf`（权限 600），也可直接编辑：执行间隔以外的修改在下次运行时生效，修改执行间隔需再执行 `cf-ddns install`。
- 记录不存在时自动新建；已存在时同步 IP 和代理状态，不修改 TTL。
- 开启代理后访问者连接的是 Cloudflare，只能用于网页服务；SSH 等直连服务使用未开代理的域名。
- 同名同类型记录存在多条时，该域名报错跳过，需在 Cloudflare 保留一条。
- 同一份配置同时只运行一个实例，手动运行与定时任务重叠时后者等待前者结束。
- 日志只记录新建、更新记录和出错；记录未变化时不写日志，在终端手动执行 `cf-ddns` 时仍会显示。
- DDNS 日志单独存放，总量约 10MB，超出时自动删除最旧的日志，不影响服务器上其它服务的日志（需 systemd 245 及以上，较低版本写入系统日志）。systemd 自身的运行失败提示可能记在系统日志中，可用 `journalctl -u cf-ddns` 查看。
- 令牌仅保存在配置文件中，不会出现在进程参数或日志中。

## IP 被墙检测

定时从服务器分别检测国内目标的 IPv4 / IPv6 能否连通；某个协议的所有目标都不通时调用服务商的接口更换 IP，等新 IP 生效后重新检测，直到恢复或达到最多更换次数，之后冷却一段时间不再更换。

### 准备

- 使用 systemd 的 Linux 服务器，以 root 执行命令（sudo 用户先执行 `sudo -i`）；较旧的 systemd（如 CentOS 7）会忽略服务单元里的部分安全选项，不影响检测功能
- 服务商提供的更换 IP 接口地址（请求该地址即更换 IP）；IPv6 单独填写接口，留空则 IPv6 不通时只记录、不更换，接口能同时换 IPv4 和 IPv6 时两处填同一个地址
- 检测目标：IPv4 默认为 `douyin.com:443,mirrors.tuna.tsinghua.edu.cn:443`，IPv6 默认为清华、中科大开源镜像站（`mirrors.tuna.tsinghua.edu.cn:443,mirrors.ustc.edu.cn:443`）。应选只在国内提供服务的目标：公共 DNS 等 Anycast 地址、在境外有 CDN 节点的网站（如 `www.douyin.com`、`www.qq.com` 的 IPv6）被墙时仍可能连通，不能用来判断；目标填错会一直判定为不通并反复更换 IP
- 系统 DNS（`/etc/resolv.conf`）如果只用了国内的 DNS（如 `114.114.114.114`），IP 被墙后域名会解析不出来，脚本连本机公网 IP 都查不到，只会记录错误而不更换 IP；请把系统 DNS 改为境外 DNS，或至少加一个境外 DNS

### 安装

```bash
curl -fsSL -o /usr/local/bin/check-ip https://raw.githubusercontent.com/ECYCloud/Server-Scripts/main/check-ip.sh && chmod 755 /usr/local/bin/check-ip && check-ip install
```

按提示依次填写：

1. 是否检测 IPv4 / IPv6（默认值按本机检测结果给出）
2. IPv4 检测目标（`域名或 IPv4:TCP 端口`）与 IPv4 不通时调用的更换 IP 接口（无默认值，必须填写）
3. IPv6 检测目标（`域名或 [IPv6]:TCP 端口`）与 IPv6 不通时调用的更换 IP 接口（留空则只记录、不更换；已填写的接口输入 `-` 清空）
4. 所有目标都不通时最多连续更换几次 IP
5. 换满次数仍不通后多少分钟内不再更换 IP（0 表示不冷却）
6. 每多少分钟检测一次

多个检测目标用英文逗号分隔；只检测其中一个协议时，不会询问另一个协议的目标和接口。

填完后先启用定时任务，再自动试运行；首次定时检测一般在安装完成或服务器开机后一个执行间隔左右。试运行时如果所有目标都不通，会真实更换 IP，通过该 IP 连接的 SSH 可能断开，试运行会在后台继续跑完（logind 开启 `KillUserProcesses` 时除外，多数发行版默认不开启），结果只显示在终端，不写入日志。缺少 flock 时会自动安装；服务器没有 curl 时先执行 `apt-get install -y curl` 或 `dnf install -y curl`。

### 修改配置

```bash
check-ip install
```

按提示修改，方括号内为当前值，直接回车保留。修改后会清除冷却状态和更换计数，新配置立即生效。

### 更新

重新执行「安装」中的命令，已有配置作为默认值，一路回车即可保留。

### 常用命令

| 操作 | 命令 |
| ---- | ---- |
| 查看最近日志 | `journalctl --namespace=check-ip -n 20 --no-pager`（systemd 低于 245 时用 `journalctl -u check-ip -n 20 --no-pager`） |
| 查看下次执行时间 | `systemctl list-timers check-ip.timer` |
| 立即执行一次（手动运行或试运行进行中时本次跳过） | `systemctl start check-ip.service` |
| 立即检测一次并在终端逐个显示检测结果，遇到能连上的目标即停止（都不通时会真实更换 IP） | `check-ip` |

### 卸载

```bash
systemctl disable --now check-ip.timer
systemctl stop check-ip.service systemd-journald@check-ip.service
rm -f /usr/local/bin/check-ip /etc/check-ip.conf /etc/systemd/system/check-ip.service /etc/systemd/system/check-ip.timer /etc/systemd/journald@check-ip.conf
rm -rf /var/lib/check-ip "/var/log/journal/$(cat /etc/machine-id).check-ip"
systemctl daemon-reload
```

### 说明

- 配置保存在 `/etc/check-ip.conf`（权限 600），也可直接编辑：执行间隔以外的修改在下次运行时生效，修改执行间隔需再执行 `check-ip install`；冷却期内直接编辑不会解除冷却，需执行 `check-ip install`。
- IPv4 与 IPv6 分别检测、分别更换、分别计算更换次数，先 IPv4 后 IPv6。检测前先确认本机能用该协议访问境外的 IP 查询服务，访问不到说明本机没有该协议的外网连接，记录错误并跳过，不更换 IP。
- 按顺序检测每个目标：域名先解析出对应协议的地址（IPv6 不使用 IPv4 映射地址），再连接 TCP 端口，每次 3 秒超时，最多试 3 次。任一目标能连上即判定正常，全部连不上才更换 IP。以 TCP 为准、不用 ping：被墙时可能 ICMP 放行而 TCP 全断，ping 仍能通。解析不到地址的目标会跳过；所有目标都解析不到时记录错误，不更换 IP。
- 能发现整个 IP 的 TCP 被封；只封了你服务所用的某个端口时，检测用的连接不经过那个端口，会判定为正常，不更换 IP。
- 调用接口时自动跟随跳转；调用失败时日志记录原因并计入更换次数。调用成功后约每 5 秒查询一次本机公网 IP，变化后才重新检测，最多等约 3 分钟；调用超时（包括连接超时）、空响应、接收中断、传输不完整或 HTTP/2 出错时请求可能已送达，同样先等 IP 变化；连接被拒绝、域名解析失败或返回 HTTP 错误时不等待。
- 更换次数记在 `/var/lib/check-ip/`，换 IP 导致服务器重启或运行被中断时，下次运行接着计数；网络恢复或停止更换（见下一条）时清零，不冷却时下次运行会重新开始一轮更换。
- 换满最多次数仍不通、调用成功后约 3 分钟内 IP 未变化，或 IPv6 未填写接口时，记录原因（调用超时等情况下 IP 未变化时，继续下一次更换并计入次数）；冷却时长大于 0 时进入冷却：冷却期内照常检测，网络恢复即解除冷却，但不更换 IP，也不再重复写日志。冷却状态同样保存在 `/var/lib/check-ip/`。
- 同时只运行一个实例：定时任务遇到手动运行或试运行时本次跳过；手动运行遇到正在运行的检测时等待其结束，最长等 300 秒，等不到时本次退出。
- 日志只记录定时任务中的更换 IP 和出错；网络正常时不写日志。在终端手动执行 `check-ip` 或安装试运行时，所有结果（包括更换 IP）只显示在终端，不写入日志。
- 日志单独存放，总量约 10MB，超出时自动删除最旧的日志（需 systemd 245 及以上，较低版本写入系统日志）。systemd 自身的运行失败提示可能记在系统日志中，可用 `journalctl -u check-ip` 查看。
- 接口地址仅保存在配置文件中，脚本不会把它写入进程参数或日志；调用失败时 curl 的错误信息可能带出接口的主机名（不含路径和参数），接口返回的内容会原样记录在日志中。
