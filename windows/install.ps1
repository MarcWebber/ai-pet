param([switch]$Launch)

$ErrorActionPreference = "Stop"
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\JellyPet"
$startMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$shortcutPath = Join-Path $startMenu "JellyPet.lnk"
$staging = "$installRoot.update"
Get-Process JellyPet -ErrorAction SilentlyContinue | Stop-Process -Force
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item $staging -ItemType Directory -Force | Out-Null
Copy-Item (Join-Path $source "*") $staging -Recurse -Force
if (Test-Path $installRoot) { Remove-Item $installRoot -Recurse -Force }
Move-Item $staging $installRoot

$executable = Join-Path $installRoot "JellyPet.exe"
if (-not (Test-Path $executable)) { throw "安装包中缺少 JellyPet.exe。" }

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $executable
$shortcut.WorkingDirectory = $installRoot
$shortcut.Description = "JellyPet 桌面任务助手"
$shortcut.Save()

Write-Host "JellyPet 已安装到 $installRoot"
if ($Launch) { Start-Process $executable }
