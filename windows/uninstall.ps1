param([switch]$RemoveUserData)

$ErrorActionPreference = "Stop"
$installRoot = Join-Path $env:LOCALAPPDATA "Programs\JellyPet"
$shortcutPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\JellyPet.lnk"
$userData = Join-Path $env:APPDATA "JellyPet"
$localData = Join-Path $env:LOCALAPPDATA "JellyPet"
Get-Process JellyPet -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item $installRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($RemoveUserData) {
    Remove-Item $userData -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $localData -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "JellyPet 已卸载。"
if (-not $RemoveUserData) {
    Write-Host "设置和回答历史仍保留。使用 -RemoveUserData 可一并删除。"
}
