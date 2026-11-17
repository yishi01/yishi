@echo off
setlocal
cd /d "%~dp0.."
set "PLUGINS_ROOT=%USERPROFILE%\.gemini\config\plugins"
set "TARGET_LINK=%PLUGINS_ROOT%\agy-mobile-bridge"

if not exist "%PLUGINS_ROOT%" mkdir "%PLUGINS_ROOT%"

if exist "%TARGET_LINK%" (
    echo Plugin target already exists at: %TARGET_LINK%
) else (
    mklink /J "%TARGET_LINK%" "%CD%"
)
pause
