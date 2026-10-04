# ========== Connect 校园网自动登录（Windows 一体化脚本） ==========
# 用法：
#   Connect-ChinaUnicom.ps1             # 登录：连上校园 WiFi 后自动认证（无参数默认行为）
#   Connect-ChinaUnicom.ps1 -Config     # 首次配置：录入学号/密码，生成本地凭据文件
#   Connect-ChinaUnicom.ps1 -Install    # 注册自动登录计划任务（需管理员，先完成 -Config）
#   Connect-ChinaUnicom.ps1 -Uninstall  # 删除自动登录计划任务（需管理员）
#
# 凭据不写死在脚本里：-Config 生成 Connect-ChinaUnicom.cfg（纯文本 Key=Value，已被
# .gitignore 排除，不会提交到仓库）。登录时用明文密码现场计算 RSA 密文（算法与门户
# 前端 security.js 一致），公钥优先向门户 pageInfo 接口在线获取，失败时退回内置兜底值。

param(
    [switch]$Config,
    [switch]$Install,
    [switch]$Uninstall
)

$TaskName   = "Connect-AutoLogin"

# 兼容打包成 exe 的场景：exe 内 $PSScriptRoot 可能为空，此时从进程路径推导脚本目录
$isExe = (Get-Process -Id $PID).ProcessName -notmatch '^(powershell|pwsh)$'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($isExe) { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
    else { (Get-Location).Path }

# 打包成 exe 后双击运行时窗口会一闪而过；exe 场景在关键退出点暂停（计划任务走 ps1，不受影响）
function Wait-ExeExit {
    if ($isExe) { Read-Host "按回车键退出" | Out-Null }
}

$ConfigFile = Join-Path $ScriptDir "Connect-ChinaUnicom.cfg"

# 内置兜底公钥模数（1024 位，2026-10 从门户 pageInfo 接口获取；指数固定 10001）
$FallbackModulusHex = "94dd2a8675fb779e6b9f7103698634cd400f27a154afa67af6166a43fc26417222a79506d34cacc7641946abda1785b7acf9910ad6a0978c91ec84d40b71d2891379af19ffb333e7517e390bd26ac312fe940c340466b4a5d4af1d65c3b5944078f96a1a51a5a53e4bc302818b7c9f63c4a1b07bd7d874cef1c3d4b2f5eb7871"

Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Numerics

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ========== Logging (file + console) ==========
$logFile = "$env:TEMP\Connect-AutoLogin.log"
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp  $Message" | Out-File -Append -FilePath $logFile -Encoding utf8
    if ($host.Name -ne 'ServerRemoteHost') {
        Write-Host $Message -ForegroundColor $Color
    }
}

# ========== RSA（与门户前端 security.js 的无填充 RSA 逐字节一致） ==========
function ConvertTo-PortalPasswordCipher {
    param([string]$PlainPassword, [string]$ModulusHex, [string]$ExponentHex = "10001")
    # 门户前端实际加密的明文是 密码 + ">" + mac；登录页 URL 无 mac 参数时前端固定用 111111111
    $plain = "$PlainPassword>111111111"
    $rev   = -join $plain[-1..-($plain.Length)]
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($rev)
    $le    = New-Object byte[] ($bytes.Length + 1)   # 末尾补 0 保证 BigInteger 为正
    [Array]::Copy($bytes, $le, $bytes.Length)
    $m = [System.Numerics.BigInteger]::new($le)

    $nb = New-Object byte[] ($ModulusHex.Length / 2 + 1)
    for ($i = 0; $i -lt $nb.Length - 1; $i++) {
        $nb[$i] = [Convert]::ToByte($ModulusHex.Substring($ModulusHex.Length - 2 - 2*$i, 2), 16)
    }
    $n = [System.Numerics.BigInteger]::new($nb)
    $e = [Convert]::ToInt64($ExponentHex, 16)

    $c = [System.Numerics.BigInteger]::ModPow($m, $e, $n)
    $out = $c.ToByteArray()
    if ($out[$out.Length-1] -eq 0) { $out = $out[0..($out.Length-2)] }
    [Array]::Reverse($out)
    return (($out | ForEach-Object { $_.ToString("x2") }) -join "").PadLeft(256, "0")
}

# ========== 获取门户 RSA 公钥（与浏览器登录前调 pageInfo 的行为一致，失败用内置兜底值） ==========
function Get-PortalPublicKey {
    param([string]$PageInfoUrl, [string]$QueryString)
    try {
        $resp = Invoke-WebRequest -Uri $PageInfoUrl -Method Post `
            -ContentType "application/x-www-form-urlencoded" `
            -Body "queryString=$QueryString" -UseBasicParsing -WebSession $session -TimeoutSec 10
        $exp = [regex]::Match($resp.Content, '"publicKeyExponent":"([^"]+)"').Groups[1].Value
        $mod = [regex]::Match($resp.Content, '"publicKeyModulus":"([^"]+)"').Groups[1].Value
        if ($exp -and $mod) { return @($exp, $mod) }
    } catch { }
    return @("10001", $FallbackModulusHex)
}

# ========== Double URL Encoding ==========
function DoubleUrlEncode {
    param([string]$Raw)
    if (-not $Raw) { return '' }
    $first = [System.Web.HttpUtility]::UrlEncode($Raw)
    $second = [System.Web.HttpUtility]::UrlEncode($first)
    return $second
}

# ========== 读取 .cfg 配置（纯文本 Key=Value，按行解析，不执行配置内容） ==========
function Read-CfgValue {
    param([string]$Path, [string]$Key)
    foreach ($line in (Get-Content -Path $Path -Encoding UTF8)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match ("^\s*" + [regex]::Escape($Key) + "\s*=\s*(.*?)\s*$")) { return $Matches[1] }
    }
    return $null
}

# ========== -Uninstall：删除自动登录计划任务 ==========
if ($Uninstall) {
    if (-not (Test-IsAdmin)) {
        Write-Error "-Uninstall 需要管理员身份运行。"
        exit 1
    }
    schtasks /Delete /TN $TaskName /F
    if ($LASTEXITCODE -ne 0) {
        Write-Host "任务 '$TaskName' 不存在或删除失败。" -ForegroundColor Yellow
        exit 1
    }
    Write-Host "任务 '$TaskName' 已删除。" -ForegroundColor Green
    exit
}

# ========== -Install：注册自动登录计划任务 ==========
if ($Install) {
    if (-not (Test-IsAdmin)) {
        Write-Error "-Install 需要管理员身份运行。"
        exit 1
    }
    if (-not (Test-Path $ConfigFile)) {
        Write-Error "尚未配置：请先运行 .\Connect-ChinaUnicom.ps1 -Config 完成初始配置。"
        exit 1
    }

    $scriptPath = Join-Path $ScriptDir "Connect-ChinaUnicom.ps1"
    if (-not (Test-Path $scriptPath)) {
        Write-Error "未找到 $scriptPath。计划任务以隐藏窗口运行 ps1，请保持 ps1 与 exe（如有）同目录。"
        exit 1
    }

    # Remove existing task
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Removing existing task..." -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    # Build the command line
    $cmd = "powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    # Trigger on WLAN connection event
    # Event ID 8001 = WLAN successfully connected
    # Channel: Microsoft-Windows-WLAN-AutoConfig/Operational
    $eventQuery = '*[System[EventID=8001]]'

    $result = schtasks /Create `
        /TN $TaskName `
        /TR $cmd `
        /SC ONEVENT `
        /EC "Microsoft-Windows-WLAN-AutoConfig/Operational" `
        /MO $eventQuery `
        /IT `
        /RL LIMITED `
        /DELAY 0000:30 `
        /F 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "schtasks failed: $result"
        exit 1
    }

    Write-Host ""
    Write-Host "Task '$TaskName' installed successfully!" -ForegroundColor Green
    Write-Host "  Trigger:    WiFi connection event (WLAN-AutoConfig Event ID 8001)" -ForegroundColor Cyan
    Write-Host "  Action:     powershell.exe -WindowStyle Hidden -File Connect-ChinaUnicom.ps1" -ForegroundColor Cyan
    Write-Host "  Log file:   `$env:TEMP\Connect-AutoLogin.log" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "To test: disconnect and reconnect WiFi, or:" -ForegroundColor Yellow
    Write-Host "  schtasks /Run /TN '$TaskName'" -ForegroundColor Yellow
    Write-Host "To remove: .\Connect-ChinaUnicom.ps1 -Uninstall" -ForegroundColor Yellow
    exit
}

# ========== -Config：首次配置向导 ==========
if ($Config) {
    Write-Host "=== 校园网自动登录 初始配置 ===" -ForegroundColor Cyan
    Write-Host "配置将保存到 $ConfigFile（本地文件，不会上传 GitHub）" -ForegroundColor DarkGray
    Write-Host ""

    $BaseUrl = (Read-Host "认证门户地址（回车默认 http://172.16.54.18/）").Trim()
    if (-not $BaseUrl) { $BaseUrl = "http://172.16.54.18/" }

    $targetSsid = (Read-Host "校园网 WiFi SSID（回车默认 iHBUT）").Trim()
    if (-not $targetSsid) { $targetSsid = "iHBUT" }

    $Username = ""
    while (-not $Username) { $Username = (Read-Host "学号/账号").Trim() }

    $PasswordPlain = ""
    while (-not $PasswordPlain) {
        $sec = Read-Host "校园网密码" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        $PasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not $PasswordPlain) { Write-Host "密码不能为空，请重新输入。" -ForegroundColor Red }
    }

    $Service = (Read-Host "运营商代码 LT/DX/YD（回车默认 LT）").Trim()
    if (-not $Service) { $Service = "LT" }

    # 写配置：纯文本 Key=Value（按 txt 读写，不当作代码执行）
    @(
        "# Connect 校园网自动登录配置（含明文密码，请勿外传或提交到仓库）"
        "BaseUrl=$BaseUrl"
        "Ssid=$targetSsid"
        "Username=$Username"
        "Password=$PasswordPlain"
        "Service=$Service"
    ) | Set-Content -Path $ConfigFile -Encoding UTF8

    Write-Host ""
    Write-Host "配置已保存: $ConfigFile" -ForegroundColor Green

    # 顺带把当前密码的 RSA 密文算出来（算法与门户前端 security.js 一致），OpenWrt 侧可直接复制
    $cipher = ConvertTo-PortalPasswordCipher -PlainPassword $PasswordPlain -ModulusHex $FallbackModulusHex
    Write-Host ""
    Write-Host "当前密码对应的 RSA 密文（供 OpenWrt 侧 eportal-login.sh 首次配置时粘贴）:" -ForegroundColor Cyan
    Write-Host $cipher
    Write-Host ""
    Write-Host "现在可以运行 .\Connect-ChinaUnicom.ps1 测试登录；" -ForegroundColor Yellow
    Write-Host "连 WiFi 自动登录可再以管理员身份运行 .\Connect-ChinaUnicom.ps1 -Install。" -ForegroundColor Yellow
    exit
}

# ========== Main：登录（无参数默认行为） ==========
if (-not (Test-Path $ConfigFile)) {
    Write-Error "未找到配置文件 $ConfigFile。首次使用请先运行 .\Connect-ChinaUnicom.ps1 -Config 完成初始配置。"
    Wait-ExeExit
    exit 1
}
. $ConfigFile

# 解析纯文本配置
$BaseUrl       = Read-CfgValue $ConfigFile "BaseUrl"
$targetSsid    = Read-CfgValue $ConfigFile "Ssid"
$Username      = Read-CfgValue $ConfigFile "Username"
$PasswordPlain = Read-CfgValue $ConfigFile "Password"
$Service       = Read-CfgValue $ConfigFile "Service"
if (-not $Username -or -not $PasswordPlain) {
    Write-Error "配置不完整（缺 Username/Password）：请重新运行 .\Connect-ChinaUnicom.ps1 -Config。"
    Wait-ExeExit
    exit 1
}

# ========== SSID Check (only run when connected to campus WiFi) ==========
$wlan = netsh wlan show interfaces 2>$null | Select-String "SSID" | Select-String $targetSsid
if (-not $wlan) { exit 0 }

# ========== Session & Headers ==========
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36 Edg/150.0.0.0"
}

# ========== Main ==========
Write-Log "Accessing portal to extract queryString..." -Color Cyan
try {
    $response = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing -MaximumRedirection 5 -WebSession $session -ErrorAction Stop
    $html = $response.Content
    $finalUri = $response.BaseResponse.ResponseUri
} catch {
    if ($_.Exception.Response.StatusCode -eq 'Found' -or $_.Exception.Response.StatusCode -eq 'Moved') {
        $redirectUrl = $_.Exception.Response.Headers['Location']
        if (-not $redirectUrl) { Write-Error "No Location header."; exit 1 }
        Write-Log "Redirected to: $redirectUrl" -Color Yellow
        if ($redirectUrl -match "success\.jsp" -or $redirectUrl -match "userIndex=") {
            Write-Log "Already authenticated (but will still attempt login)." -Color DarkYellow
        }
        $response = Invoke-WebRequest -Uri $redirectUrl -UseBasicParsing -WebSession $session
        $html = $response.Content
        $finalUri = $response.BaseResponse.ResponseUri
    } else {
        Write-Error "Cannot access portal: $_"
        exit 1
    }
}

Write-Log "Current page: $($finalUri.AbsoluteUri)" -Color DarkYellow

# Check if already authenticated (redirected to success.jsp)
if ($finalUri.AbsolutePath -match "success\.jsp") {
    if ($finalUri.Query -match 'userIndex=([^&]+)') {
        $userIndex = $matches[1]
        Write-Log "Already authenticated! userIndex: $userIndex" -Color Green
        Write-Log "You are online. No need to log in again." -Color Green
        exit 0
    }
}

# Extract raw queryString
if ($finalUri.Query) {
    $rawQueryString = $finalUri.Query.TrimStart('?')
} else {
    $qsMatch = [regex]::Match($html, 'name="queryString"[^>]*value="([^"]*)"')
    $rawQueryString = if ($qsMatch.Success) { $qsMatch.Groups[1].Value } else { '' }
}

$QueryString = DoubleUrlEncode $rawQueryString

# Determine base path
$loginPath = $finalUri.AbsolutePath
$lastSlash = $loginPath.LastIndexOf('/')
$basePath = $finalUri.Scheme + "://" + $finalUri.Host + $(if ($finalUri.Port -ne 80) {":" + $finalUri.Port}) + $loginPath.Substring(0, $lastSlash + 1)
$loginUrl = $basePath + "InterFace.do?method=login"

# 现算密文：公钥优先在线取，失败退回内置兜底值
$expHex, $modHex = Get-PortalPublicKey -PageInfoUrl ($basePath + "InterFace.do?method=pageInfo") -QueryString $rawQueryString
$EncryptedPassword = ConvertTo-PortalPasswordCipher -PlainPassword $PasswordPlain -ModulusHex $modHex -ExponentHex $expHex

Write-Log "Service: $Service" -Color Cyan
Write-Log "RSA public key: exponent=$expHex, modulus=$($modHex.Substring(0, 16))..." -Color DarkGray
Write-Log "Encoded Query: $QueryString" -Color Cyan

# Build POST body as raw string (avoids Invoke-WebRequest triple-encoding the queryString)
$postBody = "userId=$Username&password=$EncryptedPassword&service=$Service&queryString=$QueryString&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=true"

# Add Referer & Origin to headers
$headers["Referer"] = $finalUri.AbsoluteUri
$headers["Origin"] = $finalUri.Scheme + "://" + $finalUri.Host

Write-Log "Submitting login to: $loginUrl" -Color Cyan
try {
    $loginResponse = Invoke-WebRequest -Uri $loginUrl -Method Post -Body $postBody -UseBasicParsing -WebSession $session -Headers $headers
    # Decode response as UTF-8 to fix Chinese garbled text
    $content = [System.Text.Encoding]::UTF8.GetString($loginResponse.RawContentStream.ToArray())
    Write-Log "Response: $content" -Color Yellow

    if ($content -match '"result":"success"' -or $content -match '"code":0') {
        Write-Log "Authentication successful! You are online now." -Color Green
    } else {
        Write-Log "Login attempt finished." -Color Red
    }
    Wait-ExeExit
} catch {
    Write-Error "Login request failed: $_"
    Wait-ExeExit
    exit 1
}
