$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$PluginsRoot = Join-Path $env:USERPROFILE ".gemini\config\plugins"
$TargetLink = Join-Path $PluginsRoot "agy-mobile-bridge"

New-Item -ItemType Directory -Force -Path $PluginsRoot | Out-Null

if (Test-Path $TargetLink) {
    Write-Host "Plugin target already exists at: $TargetLink"
} else {
    New-Item -ItemType Junction -Path $TargetLink -Target $ProjectRoot | Out-Null
    Write-Host "Installed Antigravity plugin junction: $TargetLink -> $ProjectRoot"
}
