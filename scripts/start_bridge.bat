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

curl.exe -s --max-time 2 http://127.0.0.1:8765/api/health | findstr /C:"\"ok\"" >nul 2>&1
if not errorlevel 1 (
    echo DeepSeek Mobile Bridge is already running and healthy on http://127.0.0.1:8765/api/health
    exit /b 0
)

if "%1"=="--check" (
    start "" /B .venv\Scripts\python.exe bridge\server.py
    for /L %%i in (1,1,5) do (
        timeout /t 1 /nobreak >nul
        curl.exe -s --max-time 2 http://127.0.0.1:8765/api/health | findstr /C:"\"ok\"" >nul 2>&1
        if not errorlevel 1 (
            echo Bridge started and verified healthy on http://127.0.0.1:8765/api/health
            exit /b 0
        )
    )
    echo ERROR: Bridge failed health check after 5 retries. Log tail:
    if exist "data\bridge.log" powershell -NoProfile -Command "Get-Content data\bridge.log -Tail 30"
    exit /b 1
)

.venv\Scripts\python.exe bridge\server.py
