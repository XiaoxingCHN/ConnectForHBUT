# Connect 校园网自动登录说明（Windows 本机）

本目录只有一个脚本 `Connect-ChinaUnicom.ps1`，配合本地配置文件实现 **连上校园网 WiFi 后自动完成联通认证上线**，
无需手动打开认证页面。**脚本本身不含任何账号信息**：首次使用先用 `-Config` 录入学号/密码，凭据保存在本地配置
文件里（已被 `.gitignore` 排除，不会上传仓库）。OpenWrt 路由器侧的同类方案见仓库 `openwrt/` 目录。

| 文件 | 作用 |
|---|---|
| `Connect-ChinaUnicom.ps1` | 一体化脚本（源码）：默认运行 = 登录；`-Config` = 首次配置；`-Install` / `-Uninstall` = 注册/删除自动登录计划任务 |
| `Connect-ChinaUnicom.cfg` | 本地凭据配置（由 `-Config` 生成；纯文本 Key=Value 按 txt 读取，不当作代码执行；含明文密码，勿提交/外传） |
| `Connect-ChinaUnicom.exe` | 可选：上述脚本的 ps2exe 打包产物（本地自用，已 gitignore；双击 = 登录，参数需在 cmd/PowerShell 里传） |

> **如何运行下文命令**：在资源管理器中进入本目录，**地址栏输入 `powershell` 回车**（或右键 →"在终端中打开"），
> 即可在当前文件夹打开终端；下文命令全部是相对路径，照抄即可。
> 若提示"在此系统上禁止运行脚本"，改用这种形式（同样在当前文件夹执行）：
> `powershell -ExecutionPolicy Bypass -File .\Connect-ChinaUnicom.ps1 -Config`。

---

## 一、首次配置（-Config）

```powershell
.\Connect-ChinaUnicom.ps1 -Config
```

按提示录入认证门户地址、SSID、学号、密码（不回显）、运营商代码，全部支持回车取默认值。
配置写入同目录 `Connect-ChinaUnicom.cfg`（纯文本 `Key=Value` 格式，脚本按 txt 逐行解析，
不当作代码执行）；**换密码后重新运行一次即可**，无需抓包。
运行结束还会打印当前密码对应的 RSA 密文——配置 OpenWrt 侧脚本时直接复制它。

### 配置项（Connect-ChinaUnicom.cfg）

```ini
# Connect 校园网自动登录配置（含明文密码，请勿外传或提交到仓库）
BaseUrl=http://172.16.54.18/
Ssid=iHBUT
Username=你的学号
Password=你的密码
Service=LT
```

---

## 二、手动登录

连上校园 WiFi 后，在当前文件夹的终端里：

```powershell
.\Connect-ChinaUnicom.ps1
```

也可以右键该文件 → **使用 PowerShell 运行**。

### 脚本行为

1. **SSID 检查**：先用 `netsh wlan show interfaces` 检查当前 WiFi 是否为配置的 `$targetSsid`，不是则**直接静默退出**（不做任何事）。
2. 访问认证门户 `$BaseUrl`，跟随跳转拿到本次会话的 `queryString`。
3. 如果发现已被重定向到 `success.jsp`（说明已经在线），直接提示"已认证"并退出，不会重复登录。
4. 向门户 `pageInfo` 接口在线获取 RSA 公钥（失败退回内置兜底值），用配置里的明文密码**现场计算密文**。
5. 把 `queryString` 做**双重 URL 编码**后，连同账号、密文、运营商代码一起 POST 到 `InterFace.do?method=login` 完成认证。
6. 结果同时输出到控制台并写入日志文件。

### 日志位置

```
%TEMP%\Connect-AutoLogin.log
```

在资源管理器地址栏输入 `%TEMP%` 即可找到 `Connect-AutoLogin.log`，或用 PowerShell 查看：

```powershell
Get-Content "$env:TEMP\Connect-AutoLogin.log" -Tail 20
```

---

## 三、开机自动登录（-Install / -Uninstall）

**必须以管理员身份运行**：开始菜单搜 "PowerShell" → 右键 → 以管理员身份打开，先 `cd` 进入本目录，然后：

```powershell
# 注册计划任务（先确认已用 -Config 完成配置）
.\Connect-ChinaUnicom.ps1 -Install

# 删除计划任务
.\Connect-ChinaUnicom.ps1 -Uninstall
```

### 它做了什么

创建名为 **`Connect-AutoLogin`** 的 Windows 计划任务：

- **触发条件**：Windows 的 WLAN-AutoConfig 日志中出现 **事件 ID 8001**（即任意 WiFi 连接成功）后，**延迟 30 秒**执行（给网络留出稳定时间）；
- **执行内容**：以隐藏窗口、无参数方式运行同一脚本（即登录流程）；
- **权限**：普通用户权限（LIMITED），且仅在你登录桌面时运行（`/IT`）；
- 如果已存在同名任务，会先删除旧的再重建（可重复执行来更新）；
- **脚本定位**：计划任务指向安装时脚本的绝对路径（`$PSScriptRoot` 自动推导），以后移动目录后重跑一次 `-Install` 即可。

> 注意：任务本身对所有 WiFi 连接事件都会触发，但登录脚本第一步会检查 SSID，连的不是校园 WiFi 时脚本会自动退出，所以连手机热点等场景不会误登录。

### 安装成功后的验证

断开 WiFi 再重连，等约 30 秒后查看日志是否有登录记录；或者直接手动跑一次任务测试：

```powershell
schtasks /Run /TN "Connect-AutoLogin"
```

---

## 四、常用管理命令

```powershell
# 手动触发一次自动登录任务
schtasks /Run /TN "Connect-AutoLogin"

# 查看任务状态
schtasks /Query /TN "Connect-AutoLogin" /V

# 删除（卸载）自动登录任务（也可用 -Uninstall）
schtasks /Delete /TN "Connect-AutoLogin" /F

# 查看最近登录日志
Get-Content "$env:TEMP\Connect-AutoLogin.log" -Tail 20
```

---

## 五、密文的来源与自算（已实测验证）

登录请求里的 `password` 字段是加密后的密文（256 位十六进制）。脚本**不保存密文**：每次运行时用配置里的
明文密码现场计算，RSA 公钥优先向门户 `pageInfo` 接口在线获取，失败时退回脚本内置的兜底值。
算法经对门户前端 JS（`security.js` / `AuthInterFace.js` / `login_bch.js`）逆向得出，
并用浏览器抓包的历史密文逐字节比对验证无误。

加密原理：

1. 公钥由登录页通过 `POST /eportal/InterFace.do?method=pageInfo` 下发：指数 `10001`，模数 `94dd2a86...e2871`（1024 位）；
2. 加密的明文**不是密码本身**，而是 `密码 + ">" + mac`，其中 `mac` 取登录页 URL 的 `mac` 参数，**没有该参数时固定为 `111111111`**，所以实际明文是 `密码>111111111` 这种形式；
3. 明文先**整体反转**，再做**无随机填充的 RSA-1024** 加密，输出 256 位十六进制；
4. 因为没有随机填充，同一明文每次加密结果完全相同——这正是密文配置一次就能长期复用的原因。

**改密码后**：重新运行一次 `-Config` 录入新密码即可，脚本会自动用新密码现算，无需抓包。
下面是等价的手工计算代码（供核对，或在没有脚本的环境里生成密文）：

```powershell
Add-Type -AssemblyName System.Numerics

$Password = "你的密码"   # ← 改成当前密码
$ModulusHex = "94dd2a8675fb779e6b9f7103698634cd400f27a154afa67af6166a43fc26417222a79506d34cacc7641946abda1785b7acf9910ad6a0978c91ec84d40b71d2891379af19ffb333e7517e390bd26ac312fe940c340466b4a5d4af1d65c3b5944078f96a1a51a5a53e4bc302818b7c9f63c4a1b07bd7d874cef1c3d4b2f5eb7871"

# 明文 = 密码 + ">" + 111111111，整体反转后按小端字节序构造整数
$plain = "$Password>111111111"
$rev   = -join $plain[-1..-($plain.Length)]
$bytes = [System.Text.Encoding]::ASCII.GetBytes($rev)
$le    = New-Object byte[] ($bytes.Length + 1)   # 末尾补 0 保证 BigInteger 为正
[Array]::Copy($bytes, $le, $bytes.Length)
$m = [System.Numerics.BigInteger]::new($le)

# 模数 hex 转 BigInteger（小端 + 符号位）
$nb = New-Object byte[] ($ModulusHex.Length / 2 + 1)
for ($i = 0; $i -lt $nb.Length - 1; $i++) {
    $nb[$i] = [Convert]::ToByte($ModulusHex.Substring($ModulusHex.Length - 2 - 2*$i, 2), 16)
}
$n = [System.Numerics.BigInteger]::new($nb)

# c = m^65537 mod n，输出大端 256 位 hex
$c = [System.Numerics.BigInteger]::ModPow($m, 65537, $n)
$out = $c.ToByteArray()
if ($out[$out.Length-1] -eq 0) { $out = $out[0..($out.Length-2)] }
[Array]::Reverse($out)
(($out | ForEach-Object { $_.ToString("x2") }) -join "").PadLeft(256, "0")
```

> 抓包备用方法：F12 → Network → 手动登录一次 → 找 `InterFace.do?method=login` 的 POST 请求，复制 `password` 字段。若某天登录突然失败且账号密码无误，可重新请求一次 `pageInfo` 接口确认公钥是否被学校更换过。

---

## 附：打包 exe（可选）

习惯双击运行的话，可用 ps2exe 把脚本打成 exe（产物已 gitignore，仓库只分发源码）：

```powershell
Install-Module ps2exe -Scope CurrentUser -Force
Invoke-ps2exe -inputFile .\Connect-ChinaUnicom.ps1 -outputFile .\Connect-ChinaUnicom.exe `
    -title "Connect-ChinaUnicom" -version "1.0.0" -x64
```

- 双击 exe = 登录：已在线时窗口一闪即退；真正执行登录或出错时窗口会停住等回车，方便看结果；
  `-Config` / `-Install` 等参数需在 cmd/PowerShell 里传给 exe；
- 计划任务仍由 `-Install` 注册（隐藏窗口运行 ps1），exe 不参与自动登录；
- 改了 ps1 记得重新打包（exe 内嵌的是打包时的脚本副本）；
- **注意**：ps2exe 产物被 Defender 等杀软误报的概率较高，被拦截时加白名单或直接用 ps1 即可。

---

## 六、注意事项

- 凭据（含明文密码）只存于本地 `Connect-ChinaUnicom.cfg`（纯文本，已被 `.gitignore` 排除），切勿提交或外传；密文对应的明文是"密码 + `>` + `111111111"`整体（不是密码单独加密），细节见"密文的来源与自算"。
- 认证门户是校内地址，只有在校园网环境下才能访问，脚本在其他网络下会因 SSID 检查不通过而直接退出，属正常现象。
- 日志写在临时目录，清理系统临时文件后日志会丢失，属正常现象。
