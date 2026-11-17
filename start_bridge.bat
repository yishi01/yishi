@echo off
cd /d "%~dp0"
echo Starting DeepSeek Mobile Bridge v0.7.2 (with Cloudflare Public Tunnel)...
"C:\Python313\python.exe" bridge\server.py
pause
