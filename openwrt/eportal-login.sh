#!/bin/sh
# ePortal(锐捷) 校园网自动登录 - OpenWrt 版
# 移植自 Windows 的 Connect-ChinaUnicom.ps1，登录流程一致：
#   GET 门户 -> 跟随 302 到 index.jsp?queryString -> 双重 URL 编码 -> POST InterFace.do?method=login
# 依赖: curl  (opkg update && opkg install curl，或用仓库 ipk/ 目录离线安装)
# 配置: 脚本本身不含任何账号信息。首次在路由器上手动运行，按提示录入参数，
#       保存到 /etc/eportal.conf（root 600，勿外传）；cron 环境缺配置时仅记日志并退出。
#       换密码后删除 /etc/eportal.conf 重新运行一次即可。
# 建议配合 crontab 每 5 分钟跑一次，脚本自带在线检测，已通网会立即退出

CONFIG="/etc/eportal.conf"
PAGE_TMP="/tmp/eportal_page.html"
LOG_FILE="/tmp/eportal.log"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 Edg/150.0.0.0"

log() {
    logger -t eportal "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG_FILE"
}

# URL 编码（与 .NET HttpUtility.UrlEncode 对 ASCII 的行为一致）
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

# ── 配置：首次运行（终端）交互录入，之后只读；cron 等无终端环境缺配置直接退出 ──
if [ ! -s "$CONFIG" ]; then
    if [ -t 0 ]; then
        echo "=== 校园网自动登录 初始配置（保存到 $CONFIG） ==="
        printf '认证门户地址 [http://172.16.54.18/]: '
        read -r BASE_URL
        [ -n "$BASE_URL" ] || BASE_URL="http://172.16.54.18/"
        printf '学号/账号: '
        read -r USERID
        while [ -z "$USERID" ]; do
            printf '学号/账号（必填）: '
            read -r USERID
        done
        printf 'RSA 密文（password 字段，获取方法见 README 附录 A）: '
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

# 已通网直接退出：ping 通 223.5.5.5 就退出
if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
    exit 0
fi

# 部分网络屏蔽 ICMP（ping 不通但实际在线），用 HTTP 连通性测试兜底
command -v curl >/dev/null 2>&1 || { log "curl 未安装，请先执行: opkg update && opkg install curl"; exit 1; }
if curl -sL --max-time 5 http://www.msftconnecttest.com/connecttest.txt 2>/dev/null | grep -q "Microsoft Connect Test"; then
    exit 0
fi

# 1. 访问门户，跟随重定向，拿到最终登录页地址
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

# 2. 取 queryString：优先用最终 URL 的查询串，取不到再从页面隐藏域拿
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

# 3. 双重 URL 编码（与浏览器/PS 脚本行为一致）
qs2=$(printf '%s\n' "$raw_qs" | urlencode | urlencode)

# 4. 用登录页同目录下的 InterFace.do 提交
page_url=${final_url%%\?*}
login_url=${page_url%/*}/InterFace.do?method=login
origin=$(printf '%s' "$final_url" | cut -d/ -f1-3)

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
