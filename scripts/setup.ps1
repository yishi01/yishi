$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

$pyVer = & python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
$parts = $pyVer.Split(".")
if ([int]$parts[0] -lt 3 -or ([int]$parts[0] -eq 3 -and [int]$parts[1] -lt 11)) {
    Write-Error "Python >= 3.11 is required (found $pyVer)"
    exit 1
}

$VenvPython = Join-Path $ProjectRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $VenvPython)) {
    Write-Host "[setup] Creating .venv..."
    & python -m venv (Join-Path $ProjectRoot ".venv")
}

Write-Host "[setup] Installing requirements into .venv..."
& $VenvPython -m pip install -q -r (Join-Path $ProjectRoot "requirements.txt")
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "[setup] Running pytest suite..."
& $VenvPython -m pytest -q
exit $LASTEXITCODE
