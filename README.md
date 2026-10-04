# Connect — 校园网 ePortal 自动认证(湖北工业大学)

锐捷 ePortal 网页认证校园网（联通线路）的自动登录工具，Windows 本机与 OpenWrt 路由器两套实现，
协议流程一致：**GET 门户 → 跟随 302 取 `queryString` → 双重 URL 编码 → POST `InterFace.do?method=login`**。

## 目录结构

```text
Connect/
├── windows/                        # Windows 本机
│   ├── Connect-ChinaUnicom.ps1     # 一体化脚本：默认=登录；-Config=首次配置；-Install/-Uninstall=计划任务
│   ├── README.md                   # 详细用法：首次配置 / 手动运行 / 自启安装 / 密文自算
│   └── Connect-ChinaUnicom.cfg     # 本地凭据（纯文本 Key=Value，-Config 生成，gitignore 不入库）
└── openwrt/                        # OpenWrt 路由器
    ├── eportal-login.sh            # 登录脚本：首次运行录入参数存 /etc/eportal.conf，cron 每 5 分钟保活
    ├── README.md                   # 完整方案：STA 上联 / 部署 / 踩坑实录 / 排障
    └── ipk/                        # curl 离线依赖闭包（aarch64_cortex-a53）及索引
```

## 快速开始

**Windows**：进入 `windows/` 目录，**地址栏输入 `powershell` 回车**在当前文件夹打开终端，运行
`.\Connect-ChinaUnicom.ps1 -Config` 录入学号和密码（保存在本地 `Connect-ChinaUnicom.cfg` 纯文本，
已 gitignore），`.\Connect-ChinaUnicom.ps1` 测试登录；管理员终端中 `cd` 进入该目录再运行
`.\Connect-ChinaUnicom.ps1 -Install` 注册连 WiFi 自动登录。详见 [windows/README.md](windows/README.md)。

**OpenWrt**：路由器以无线 STA 接入校园网，`ipk/` 离线装好 curl，首次手动运行 `eportal-login.sh`
按提示录入参数（保存在路由器 `/etc/eportal.conf`），加进 crontab（`*/5 * * * *`）即可掉线自愈。
详见 [openwrt/README.md](openwrt/README.md)。

## 使用前配置

脚本与仓库本身**不含任何账号凭据**：Windows 侧首次运行 `Connect-ChinaUnicom.ps1 -Config`、OpenWrt 侧
首次手动运行登录脚本，按提示录入自己学校环境的参数（门户地址 / 账号 / 密码或密文 / 运营商代码 / SSID）。
密码密文的原理与本地自算方法见 [windows/README.md](windows/README.md) 的"密文的来源与自算"一节。

