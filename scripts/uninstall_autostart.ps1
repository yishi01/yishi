$ErrorActionPreference = "SilentlyContinue"
Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "DeepSeekMobileBridge" -ErrorAction SilentlyContinue
$StartupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "DeepSeekMobileBridge.lnk"
if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
schtasks /Delete /TN "DeepSeekMobileBridge" /F 2>$null | Out-Null
Write-Host "[OK] 已移除 DeepSeek Mobile Bridge 开机自启动项。" -ForegroundColor Yellow
