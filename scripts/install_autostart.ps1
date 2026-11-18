<#
.SYNOPSIS
    配置 DeepSeek Mobile Bridge 开机/登录自动启动（自动启动后端服务 + Cloudflare 隧道）。
.DESCRIPTION
    1. 默认无需管理员权限即可安装 HKCU 登录自启动（Run 注册表 + 开始菜单启动目录快捷方式），
       后台通过 pythonw.exe 无窗口运行 watchdog_launcher.py 守护进程。
    2. 如果以「管理员身份」运行本脚本，还会额外注册 Windows 计划任务 DeepSeekMobileBridge
       （支持系统开机启动 ONSTART + 崩溃自动重启）及全网络配置防防火墙放行规则。
#>
param(
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$WatchdogScript = Join-Path $RepoRoot "bridge\watchdog_launcher.py"

$PythonW = "C:\Python313\pythonw.exe"
if (-not (Test-Path $PythonW)) {
    $cmd = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($cmd) { $PythonW = $cmd.Source }
    else { throw "未找到 pythonw.exe，请先确认 Python 已安装。" }
}

$PythonExe = "C:\Python313\python.exe"
if (-not (Test-Path $PythonExe)) {
    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($cmd) { $PythonExe = $cmd.Source }
}

$LaunchCmd = "`"$PythonW`" `"$WatchdogScript`""

# 1. HKCU Run 注册表自启动（免管理员权限，登录后立即后台无窗启动）
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
New-ItemProperty -Path $RunKey -Name "DeepSeekMobileBridge" -Value $LaunchCmd -PropertyType String -Force | Out-Null

# 2. Startup 启动目录快捷方式（双保险，watchdog_launcher 内部有 PID/端口单实例互斥保护）
$Wsh = New-Object -ComObject WScript.Shell
$StartupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "DeepSeekMobileBridge.lnk"
$Shortcut = $Wsh.CreateShortcut($StartupLnk)
$Shortcut.TargetPath = $PythonW
$Shortcut.Arguments = "`"$WatchdogScript`""
$Shortcut.WorkingDirectory = $RepoRoot
$Shortcut.Description = "DeepSeek Mobile Bridge Auto-Start & Cloudflare Tunnel Watchdog"
$Shortcut.Save()

# 3. 检测当前是否为管理员，若是则额外注册开机计划任务（未登录桌面也能启动）与全网络防火墙规则
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if ($IsAdmin) {
    schtasks /Create /TN "DeepSeekMobileBridge" /TR $LaunchCmd /SC ONSTART /RU "SYSTEM" /RL HIGHEST /F | Out-Null
    $fwRule = "DeepSeek Mobile Bridge TCP 8765"
    if (-not (Get-NetFirewallRule -DisplayName $fwRule -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $fwRule -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 -Profile Any | Out-Null
    }
    if (-not $Silent) { Write-Host "[OK] 已注册系统级开机计划任务 (ONSTART) 及全网络防火墙放行。" -ForegroundColor Green }
} else {
    if (-not $Silent) { Write-Host "[OK] 已配置当前用户开机/登录自动后台无窗启动（HKCU Run + Startup 快捷方式）。" -ForegroundColor Green }
    if (-not $Silent) { Write-Host "[TIP] 如需连锁屏前未登录桌面也自动开机启动，请右键「以管理员身份」运行本脚本一次即可。" -ForegroundColor Yellow }
}
