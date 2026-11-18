@echo off
setlocal
cd /d "%~dp0.."

python -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)"
if errorlevel 1 (
    echo ERROR: Python 3.11+ is required.
    exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
    echo Creating .venv and installing dependencies...
    python -m venv .venv
    .venv\Scripts\python.exe -m pip install -r requirements.txt
)

set "BRIDGE_PORT=8765"
if exist "data\config.json" (
    for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "try { (Get-Content data\config.json -Raw | ConvertFrom-Json).port } catch { 8765 }"`) do (
        if not "%%p"=="" set "BRIDGE_PORT=%%p"
    )
)

curl.exe -s --max-time 2 http://127.0.0.1:%BRIDGE_PORT%/api/health | findstr /C:"\"ok\"" >nul 2>&1
if not errorlevel 1 (
    echo DeepSeek Mobile Bridge is already running and healthy on http://127.0.0.1:%BRIDGE_PORT%/api/health
    exit /b 0
)

if "%1"=="--check" (
    start "" /B .venv\Scripts\python.exe bridge\server.py
    for /L %%i in (1,1,5) do (
        timeout /t 1 /nobreak >nul
        curl.exe -s --max-time 2 http://127.0.0.1:%BRIDGE_PORT%/api/health | findstr /C:"\"ok\"" >nul 2>&1
        if not errorlevel 1 (
            echo Bridge started and verified healthy on http://127.0.0.1:%BRIDGE_PORT%/api/health
            exit /b 0
        )
    )
    echo ERROR: Bridge failed health check after 5 retries. Log tail:
    if exist "data\bridge.log" powershell -NoProfile -Command "Get-Content data\bridge.log -Tail 30"
    exit /b 1
)

.venv\Scripts\python.exe bridge\server.py
