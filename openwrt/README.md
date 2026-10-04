# OpenWrt 校园网锐捷 ePortal 自动认证方案

> 让一台 OpenWrt 路由器以 WiFi 客户端（STA）方式接入校园网，自动完成 Web 门户认证，
> 下游所有设备（LAN 口 / 自建热点 / 交换机级联的路由器）免认证直接上网，
> 掉线自动重连、会话过期自动重登、重启自动恢复，全程无人值守。

- **认证系统**：锐捷 ePortal（网页跳转登录的那种）
- **验证环境**：OpenWrt 24.10.4（mediatek/filogic，aarch64_cortex-a53）
- **上联方式**：5G 无线 STA（开放网络 + 门户认证），有线口全部留给下游
- **依赖**：curl（约 700KB 离线包，见部署章节）

---

## 一、工作原理：先把协议逆向清楚

锐捷 ePortal 的网页登录，剥开看就是三个 HTTP 请求。**在电脑上连校园 WiFi，按 F12 抓一次正常登录**，就能看到全过程：

```text
① GET  http://<认证服务器>/                （访问任意 HTTP 站点会被 302 到这里）
      ↓ 302 重定向，Location 里自动带上了你的身份参数
② 落地 /eportal/index.jsp?queryString=wlanuserip=10.x.x.x&wlanacname=xxx
        &nasip=x.x.x.x&wlanparameter=<你的MAC>&url=<原目标>&userlocation=<物理端口>
      ↓ 从地址栏取出 queryString，做【双重 URL 编码】
③ POST /eportal/InterFace.do?method=login
      Content-Type: application/x-www-form-urlencoded
      Referer/Origin: 登录页地址（部分后端校验）

      body:
      userId=<学号>                       账号
      password=<RSA密文>                  见下方说明
      service=<运营商代码>                如 LT/联通、DX/电信、YD/移动
      queryString=<双重编码后的串>        服务器靠它识别"你是哪个出口上的谁"
      operatorPwd=&operatorUserId=&validcode=
      passwordEncrypt=true
      ↓
      响应 JSON 含 "result":"success" 即认证成功
```

### 三个关键技术点

1. **密码密文是确定性的**。锐捷前端用固定 RSA 公钥加密且无随机填充，同一明文永远得到同一串密文。
   所以把密文配置一次即可长期复用，**设备上不需要跑任何加密代码**。
   （改密码后重新录入一次密文。）

2. **queryString 要双重 URL 编码**。这是 ePortal 前端 JS 的怪癖：表单提交时编码了一次，
   HTTP 层又编码一次。少一层服务器认不出会话，直接报错。

3. **密文和编码必须与浏览器逐字节一致**。本方案的 awk 编码函数经过与
   .NET `HttpUtility.UrlEncode` 对真实 queryString 的双端 diff 验证（字符白名单 `_.!~*()-`、
   小写十六进制），保证服务器看到和浏览器完全相同的字节流。

## 二、网络架构

```text
                        校园 WiFi (SSID，开放网络 + 门户认证)
                              ║
              ┌───────────────╨──────────────┐
              │  无线 STA（5G radio，wifinet4）│  ← 关联后由 wwan 接口管理
              │  wwan: proto=dhcp            │  ← 拿校园网 10.x.x.x 地址
              │  防火墙 wan 区 / NAT伪装       │
              │                              │
              │  OpenWrt 主机                 │
              │  cron: */5 自动认证脚本        │
              │  br-lan: 192.168.11.0/24     │
              └───────┬──────────────┬───────┘
                      │              │
              LAN1-4 网线口       自建热点（2.4G AP）
                      │              │
              交换机→下游路由器    手机/电脑
              （全部免认证，共享同一个会话）
```

校园网自始至终只看到 **一个 MAC、一个 IP、一个账号会话**。

## 三、完整脚本

> 保存为 `/root/eportal-login.sh`。脚本本身不含凭据：首次在路由器上手动运行时按提示录入参数，
> 之后保存于 `/etc/eportal.conf`（root 600）。

```sh
#!/bin/sh
# ePortal(锐捷) 校园网自动登录 - OpenWrt 版
# 流程: 在线检测 -> GET门户取queryString -> 双重URL编码 -> POST InterFace.do?method=login
# 依赖: curl   配合 cron 每 5 分钟运行，已在线时静默退出

CONFIG="/etc/eportal.conf"      # 凭据文件：首次运行交互录入生成（root 600，勿入仓库/勿外传）
PAGE_TMP="/tmp/eportal_page.html"
LOG_FILE="/tmp/eportal.log"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

log() {
    logger -t eportal "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG_FILE"
}

# URL 编码（与 .NET HttpUtility.UrlEncode 对 ASCII 行为逐字节一致）
urlencode() {
    awk 'BEGIN {
        for (i = 1; i < 256; i++) hex[sprintf("%c", i)] = sprintf("%%%02x", i)
    }
    {
        r = ""
        for (j = 1; j <= length($0); j++) {
            c = substr($0, j, 1)
            if (c ~ /[A-Za-z0-9_.!~*()\-]/) r = r c
            else r = r hex[c]
        }
        print r
    }'
}

# ── 配置：首次运行（终端）交互录入，之后只读；cron 无终端时缺配置仅记日志退出 ──
if [ ! -s "$CONFIG" ]; then
    if [ -t 0 ]; then
        echo "=== 校园网自动登录 初始配置（保存到 $CONFIG） ==="
        printf '认证门户地址 [http://<认证服务器IP>/]: '
        read -r BASE_URL
        [ -n "$BASE_URL" ] || BASE_URL="http://<认证服务器IP>/"
        printf '学号/账号: '
        read -r USERID
        while [ -z "$USERID" ]; do
            printf '学号/账号（必填）: '
            read -r USERID
        done
        printf 'RSA 密文（password 字段，获取方法见附录 A）: '
        read -r PASSWORD
        while [ -z "$PASSWORD" ]; do
            printf 'RSA 密文（必填）: '
            read -r PASSWORD
        done
        printf '运营商代码 LT/DX/YD [LT]: '
        read -r SERVICE
        [ -n "$SERVICE" ] || SERVICE="LT"
        umask 077
        cat > "$CONFIG" <<EOF
# 校园网自动登录配置（含凭据，勿外传）
BaseUrl=$BASE_URL
Username=$USERID
Password=$PASSWORD
Service=$SERVICE
EOF
        chmod 600 "$CONFIG"
        log "配置已保存到 $CONFIG，开始首次登录"
    else
        log "缺少配置 $CONFIG：首次使用请在路由器上手动运行一次本脚本完成录入"
        exit 1
    fi
fi

# ── 读取配置：纯文本 Key=Value 按行解析，不当作 shell 代码执行 ──
cfg_get() {
    sed -n "s/^$1=//p" "$CONFIG" | head -n 1
}
BASE_URL=$(cfg_get BaseUrl)
USERID=$(cfg_get Username)
PASSWORD=$(cfg_get Password)
SERVICE=$(cfg_get Service)
if [ -z "$USERID" ] || [ -z "$PASSWORD" ]; then
    log "配置不完整（缺 Username/Password）：删除 $CONFIG 后重新运行本脚本完成录入"
    exit 1
fi

# ── 三级在线检测：在线就静默退出（cron 友好） ──
if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
    exit 0
fi
command -v curl >/dev/null 2>&1 || { log "curl 未安装，请先: opkg update && opkg install curl"; exit 1; }
# 部分校园网屏蔽 ICMP，用 HTTP 内容检测兜底（与 Windows 判断"无Internet"同源）
if curl -sL --max-time 5 http://www.msftconnecttest.com/connecttest.txt 2>/dev/null \
   | grep -q "Microsoft Connect Test"; then
    exit 0
fi

# ── 1. 访问门户，跟随重定向，取最终落地 URL ──
final_url=$(curl -sL -A "$UA" -o "$PAGE_TMP" -w '%{url_effective}' --max-time 15 "$BASE_URL")
if [ -z "$final_url" ]; then
    log "无法访问认证服务器 $BASE_URL（WAN 未连接？）"
    exit 1
fi

case "$final_url" in
    *success.jsp*)
        log "已有在线会话，无需登录"
        exit 0
        ;;
esac

# ── 2. 提取 queryString：优先取 URL 查询串，兜底挖页面隐藏域 ──
raw_qs=${final_url#*\?}
[ "$raw_qs" = "$final_url" ] && raw_qs=""
if [ -z "$raw_qs" ]; then
    raw_qs=$(sed -n 's/.*name="queryString"[^>]*value="\([^"]*\)".*/\1/p' "$PAGE_TMP" | head -n 1)
    raw_qs=${raw_qs//&amp;/&}
fi
if [ -z "$raw_qs" ]; then
    log "未取到 queryString，登录页异常：$final_url"
    exit 1
fi

# ── 3. 双重 URL 编码 ──
qs2=$(printf '%s\n' "$raw_qs" | urlencode | urlencode)

# ── 4. 从落地 URL 现场推导登录接口地址（不写死路径） ──
page_url=${final_url%%\?*}
login_url=${page_url%/*}/InterFace.do?method=login
origin=$(printf '%s' "$final_url" | cut -d/ -f1-3)

# ── 5. 提交登录（--data 原样发送，禁止二次编码） ──
resp=$(curl -s --max-time 15 -A "$UA" \
    -H "Referer: $final_url" \
    -H "Origin: $origin" \
    --data "userId=$USERID&password=$PASSWORD&service=$SERVICE&queryString=$qs2&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=true" \
    "$login_url")

case "$resp" in
    *'"result":"success"'*|*'"code":0'*)
        log "登录成功"
        exit 0
        ;;
    *)
        log "登录未成功，响应: $resp"
        exit 1
        ;;
esac
```

## 四、部署指南（从零到通）

### 4.1 配置无线上联（STA + wwan）

```sh
# 无线 STA：加入校园 SSID（开放网络）
uci set wireless.wwansta=wifi-iface
uci set wireless.wwansta.device='radio1'          # 你的 5G 射频
uci set wireless.wwansta.mode='sta'
uci set wireless.wwansta.network='wwan'
uci set wireless.wwansta.ssid='<校园SSID>'
uci set wireless.wwansta.encryption='none'

# 逻辑接口：由它管理 STA 拿 IP
uci set network.wwan=interface
uci set network.wwan.proto='dhcp'

# 防火墙：wwan 归入 wan 区（默认配置 wan 区已含 NAT 伪装）
uci add_list firewall.@zone[1].network='wwan'

uci commit
wifi reload
sleep 15
ubus call network.interface.wwan status   # 预期 up:true + 校园网 IP
```

> **时序大坑**：如果 STA 关联发生在外则 wwan 接口创建之前，netifd 会错过 link-up 事件，
> wwan 永远 `pending:true`。修复：把 STA 禁用再启用，强制重放完整事件流——
> ```sh
> uci set wireless.wwansta.disabled='1'; uci commit wireless; wifi reload; sleep 3
> uci set wireless.wwansta.disabled='0'; uci commit wireless; wifi reload
> ```

### 4.2 安装 curl（未认证网络的离线姿势）

路由器未认证时 `opkg` 无法联网，还会遇到"本地 ipk 与缓存列表同版本时 opkg 仍走网络下载"的坑。
正确姿势是**在能上网的电脑上下载依赖闭包，scp 上去离线装**：

```powershell
# 电脑上：从官方仓库下载（架构按自己的设备改）
# https://downloads.openwrt.org/releases/<版本>/packages/<架构>/packages/
curl_*.ipk  libcurl4_*.ipk  libmbedtls21_*.ipk  ca-bundle_*.ipk  libnghttp2-14_*.ipk

scp -O *.ipk root@192.168.11.1:/tmp/
```

```sh
# 路由器上：先清缓存列表，再离线安装
rm -f /var/opkg-lists/*
opkg install /tmp/*.ipk
```

依赖闭包：`curl → libcurl4 → libmbedtls21 + ca-bundle + libnghttp2-14`（libc/zlib 系统自带）。
不确定依赖时，下载对应仓库的 `Packages` 索引文件查 `Depends:` 字段。

> 本仓库 `ipk/` 目录已附带验证环境所用架构（aarch64_cortex-a53，OpenWrt 24.10.4）的全套
> 依赖闭包和索引文件，同架构设备可直接 `scp` 整个目录离线安装；其他架构请按上文自行下载。

### 4.3 部署脚本 + 保活

```sh
chmod +x /root/eportal-login.sh
/root/eportal-login.sh          # 首次运行：按提示录入参数（写入 /etc/eportal.conf）并登录
cat /tmp/eportal.log            # 应出现"登录成功"
ping -c 3 223.5.5.5             # 通了就是真在线

# cron：掉线/过期/重启后 ≤5 分钟自愈
echo '*/5 * * * * /root/eportal-login.sh' >> /etc/crontabs/root
/etc/init.d/cron enable && /etc/init.d/cron restart
```

> Windows 侧注意：新版 `scp` 默认走 SFTP 协议，OpenWrt 的 dropbear 没带 SFTP 服务端，
> 会报 `/usr/libexec/sftp-server: not found`。用 `scp -O` 强制旧协议，
> 或在路由器上 `opkg install openssh-sftp-server`。

## 五、踩坑实录（按层排列，每条都真实踩过）

| # | 现象 | 层 | 原因 | 解法 |
|---|------|----|------|------|
| 1 | `scp` 报 `sftp-server not found` | 工具 | 新版 OpenSSH 默认 SFTP 协议 | `scp -O` 或装 openssh-sftp-server |
| 2 | `opkg` 报 `Operation not permitted` | 网络 | 未认证时校园网防火墙 REJECT | 见 4.2 离线安装 |
| 3 | 本地 .ipk 在，opkg 却去联网下载 | 包管理 | 缓存列表有同版本时优先仓库 | `rm -f /var/opkg-lists/*` |
| 4 | `cannot find dependency libcurl4` | 包管理 | 依赖闭包不完整 | 按 Packages 索引递归补齐 |
| 5 | `ubus` 报 WAN `NO_DEVICE` | 接口 | 上联是无线上，非有线 WAN | 建 STA + wwan（4.1） |
| 6 | WiFi 显示已关联，`ip route` 却无默认路由 | 接口 | 无逻辑接口管理 STA 的 IP | `network.wwan` proto=dhcp |
| 7 | wwan 永远 `pending:true` | 时序 | STA 关联早于 wwan 存在，事件丢失 | STA 禁用→启用重放事件流 |
| 8 | 脚本报"curl: not found"但日志误导 | 脚本 | 缺依赖时错误信息含混 | 加 `command -v` 前置检查 |
| 9 | ping 不通但 HTTPS 正常 | 网络 | 校园网屏蔽 ICMP | 在线检测加 HTTP 内容兜底 |
| 10 | 重启后 `/tmp/eportal.log` 消失 | 系统 | /tmp 是 tmpfs，重启清空 | 正常现象，日志看 logread 也行 |

## 六、排障手册

```sh
# 一次体检，自上而下定位
ubus call network.interface.wwan status   # 接口层：up? 有 IP?
ip route                                   # 路由层：有 default via ... dev phyX-sta0 吗
ping -c 3 223.5.5.5                        # 连通层：通=已认证
cat /tmp/eportal.log                       # 应用层：脚本最后一次说了什么
logread | grep -i eportal                  # syslog 里的脚本记录
```

| 症状 | 判定 |
|------|------|
| `"up": false` + `NO_DEVICE` | wwan 没绑上网卡 → 4.1 时序坑 |
| 有 IP 但 ping 全丢 | 未认证，跑脚本看响应 |
| 日志"登录未成功，响应: ..." | 服务器拒绝，看响应内容：密码错/账号已在线/欠费 |
| 路由器通、客户端不通 | 客户端缓存了门户页 → 无痕窗口验证 |

**单账号互踢**：同一账号在别处（如电脑的自动登录任务）在线，会互相踢下线。
同一套网络里只保留一处用该账号认证即可。

## 七、进阶玩法

- **交换机级联**：LAN 口→交换机→多台路由器 WAN 口。下游路由器的 LAN 网段必须互不相同且
  ≠192.168.11.x，否则路由错乱。只想扩 WiFi 覆盖的下游路由器设为 AP 模式更干净。
- **多账号带宽叠加**：另一个 radio 挂第二条 STA 连 2.4G（AP+STA 可共存于一个 radio），
  脚本改造为多实例（curl 加 `--interface` 绑定各自网卡、各自账号），
  配 `mwan3 + luci-app-mwan3` 负载均衡。注意单线程速度不变、跨频段才不抢空口、
  必须不同账号否则互踢。
- **校园网侧远程管理**：默认防火墙拒绝 wan 区入站（安全，保持）。确需 SSH 时加
  `src='wan' src_ip='10.0.0.0/8' proto='tcp' dest_port='22' target='ACCEPT'` 的规则，
  并确保 root 为强密码。

## 八、安全与合规声明

- 本方案在**自己拥有管理权的设备**上模拟正常的网页登录流程，不破解、不绕过任何认证机制。
- 脚本与仓库本身不含凭据，账号信息只存在路由器本地 `/etc/eportal.conf`（root 600）；
  **请勿外传该配置文件，或把脚本部署到他人可访问的主机**。
- 多设备共享可能与部分学校的网络使用条款冲突，风险自担；下游设备数量请保持克制。
- 请勿将本方案用于代刷、售卖共享等商业行为。

## 附录 A：如何获取你自己学校的参数

1. 电脑连校园 WiFi，打开浏览器 F12 → Network，随便访问一个 HTTP 网站；
2. 抓到的 302 跳转目标就是 **认证服务器 IP** 和 **queryString 结构**；
3. 手动登录一次，找 `InterFace.do?method=login`（或同类）的 POST 请求；
4. From Data 里依次复制：`userId`→学号、`password`→RSA 密文、`service`→运营商代码；
5. 以上值在 `eportal-login.sh` 首次运行时按提示填入即可。换密码后删除 `/etc/eportal.conf` 重跑。

> 用 Windows 侧脚本的话更省事：`Set-ConnectConfig.ps1` 运行结束会直接打印当前密码对应的
> RSA 密文（本地现算，无需抓包），复制给路由器配置用。

## 附录 B：验证编码一致性（开发时用的对拍方法）

```powershell
# PowerShell 侧（.NET 行为基准）
Add-Type -AssemblyName System.Web
[System.Web.HttpUtility]::UrlEncode([System.Web.HttpUtility]::UrlEncode('<真实queryString>'))

# 路由器/本地侧
printf '%s\n' '<真实queryString>' | urlencode | urlencode

# 两边输出 diff，必须逐字节一致
```
