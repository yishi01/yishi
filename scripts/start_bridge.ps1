param(
    [switch]$Background
)
$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

# 1. Python version check (>= 3.11)
$pyVer = & python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
$parts = $pyVer.Split(".")
if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 11)) {
    Write-Error "Python >= 3.11 is required (found $pyVer)"
    exit 1
}

# 2. Ensure .venv exists
$VenvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    Write-Host "Creating .venv and installing dependencies..."
    & python -m venv (Join-Path $ProjectRoot ".venv")
    & $VenvPython -m pip install -r (Join-Path $ProjectRoot "requirements.txt")
}

# 3. Read configured port (default 8765) and check port occupancy
$Port = 8765
$CfgPath = Join-Path $ProjectRoot "data\config.json"
if (Test-Path $CfgPath) {
    try {
        $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json
        if ($cfg.port) { $Port = [int]$cfg.port }
    } catch {}
}

$HealthUrl = "http://127.0.0.1:$Port/api/health"
$existing = & curl.exe -s --max-time 2 $HealthUrl 2>$null
if ($existing -match '"status"\s*:\s*"ok"') {
    Write-Host "DeepSeek Mobile Bridge is already running and healthy at $HealthUrl"
    exit 0
}

$inUse = netstat -ano | Select-String "127.0.0.1:$Port\s+.*LISTENING|0.0.0.0:$Port\s+.*LISTENING"
if ($inUse) {
    Write-Error "Port $Port is occupied by an unresponsive process:`n$inUse"
    exit 1
}

$LogFile = Join-Path $ProjectRoot "data\bridge.log"

if ($Background) {
    Start-Process -FilePath $VenvPython -ArgumentList "bridge\server.py" -WorkingDirectory $ProjectRoot -WindowStyle Hidden
    for ($i = 1; $i -le 5; $i++) {
        Start-Sleep -Seconds 1
        $resp = & curl.exe -s --max-time 2 $HealthUrl 2>$null
        if ($resp -match '"status"\s*:\s*"ok"') {
            Write-Host "Bridge started and verified healthy ($HealthUrl): $resp"
            exit 0
        }
    }
    Write-Host "ERROR: Bridge failed health check after 5 attempts. Log tail:"
    if (Test-Path $LogFile) { Get-Content $LogFile -Tail 30 }
    exit 1
} else {
    & $VenvPython (Join-Path $ProjectRoot "bridge\server.py")
}
