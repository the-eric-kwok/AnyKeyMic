param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'AnyKeyMic.lnk'
if ($Remove) {
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
    Write-Output '已移除 AnyKeyMic 登录启动项。'
    exit
}
$binary = Join-Path $PSScriptRoot '..\dist\anykey-mic.exe'
if (!(Test-Path -LiteralPath $binary)) { throw '先运行 scripts/package-windows.ps1。' }
$binary = (Resolve-Path -LiteralPath $binary).Path
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = (Join-Path $PSScriptRoot 'run-hidden.vbs')
$shortcut.WorkingDirectory = Split-Path -Parent $binary
$shortcut.Description = 'AnyKeyMic USB 麦克风桥接'
$shortcut.Save()
Write-Output '已设置下次登录自动运行。当前进程没有启动。'
