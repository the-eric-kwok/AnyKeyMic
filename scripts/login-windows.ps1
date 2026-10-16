param(
    [ValidateSet('install','uninstall','start','stop','restart','status')]
    [string]$Action = 'install',
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
if ($Remove) { $Action = 'uninstall' }
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'AnyKeyMic.lnk'
$runner = Join-Path $PSScriptRoot 'run-hidden.vbs'
$binary = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\dist\anykey-mic.exe'))
$logFile = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AnyKeyMic\run.log'
function Get-AnyKeyMicProcess {
    Get-Process -Name 'anykey-mic' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq $binary) } catch { $false }
    }
}
function Start-ServiceProcess {
    if (!(Test-Path -LiteralPath $binary)) { throw 'Run scripts/package-windows.ps1 first.' }
    if (Get-AnyKeyMicProcess) { Write-Output 'Already running.'; return }
    $config = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AnyKeyMic\config.json'
    if (!(Test-Path -LiteralPath $config)) { throw 'Configure a virtual audio device before starting.' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + $runner + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (!(Get-AnyKeyMicProcess)) { throw "Startup failed. Check $logFile" }
    Write-Output 'Process is running. Check the log to confirm audio device connection.'
}
function Stop-ServiceProcess {
    $processes = @(Get-AnyKeyMicProcess)
    if (!$processes) { Write-Output 'Service is not running.'; return }
    Write-Warning 'Forced termination cannot guarantee that the microphone stop command is sent.'
    $processes | ForEach-Object { Stop-Process -Id $_.Id -Force; $_.WaitForExit() }
    Write-Output 'Service stopped.'
}
function Install-Service {
    if (!(Test-Path -LiteralPath $binary)) { throw 'Run scripts/package-windows.ps1 first.' }
    New-Item -ItemType Directory -Force -Path $startup | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $shortcut.Arguments = '"' + $runner + '"'
    $shortcut.WorkingDirectory = Split-Path -Parent $binary
    $shortcut.Description = 'AnyKeyMic USB microphone bridge'
    $shortcut.Save()
    Start-ServiceProcess
    Write-Output 'Per-user logon startup installed.'
}
function Uninstall-Service {
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
    Stop-ServiceProcess
    Write-Output 'Per-user logon startup uninstalled.'
}
function Show-Status {
    Write-Output ('Installed: ' + (Test-Path -LiteralPath $shortcutPath))
    Write-Output ('Running: ' + [bool]@(Get-AnyKeyMicProcess))
    Write-Output ('Binary: ' + $binary)
    Write-Output ('Log: ' + $logFile)
}
switch ($Action) {
    install { Install-Service }
    uninstall { Uninstall-Service }
    start { Start-ServiceProcess }
    stop { Stop-ServiceProcess }
    restart { Stop-ServiceProcess; Start-ServiceProcess }
    status { Show-Status }
}
