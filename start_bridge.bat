@echo off
cd /d "%~dp0"
echo Starting DeepSeek Mobile Bridge v0.8.1 (Resilient SelectorEventLoop + Watchdog)...
"C:\Python313\python.exe" bridge\watchdog_launcher.py
pause
