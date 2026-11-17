@echo off
setlocal
cd /d "%~dp0.."

if not exist ".venv\Scripts\python.exe" (
    echo [setup] Creating .venv...
    python -m venv .venv
    if errorlevel 1 exit /b 1
)

echo [setup] Installing requirements into .venv...
.venv\Scripts\python.exe -m pip install -q -r requirements.txt
if errorlevel 1 exit /b 1

echo [setup] Running pytest suite...
.venv\Scripts\python.exe -m pytest -q
exit /b %ERRORLEVEL%
