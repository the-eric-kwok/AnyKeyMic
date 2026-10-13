param([ValidateSet('test','build','release','devices')][string]$Action = 'test')
$ErrorActionPreference = 'Stop'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT','User')
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw '需要 Visual Studio C++ 构建工具。' }
& (Join-Path $vs 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
Push-Location (Join-Path $PSScriptRoot '..')
try {
    switch ($Action) {
        test { swift test }
        build { swift build }
        release { swift build -c release }
        devices { swift run anykey-mic devices }
    }
    if ($LASTEXITCODE -ne 0) { throw "Swift 命令失败：$LASTEXITCODE" }
} finally { Pop-Location }
