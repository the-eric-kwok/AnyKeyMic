param(
    [ValidateSet('help','test','build','release','devices','configure')][string]$Action = 'help',
    [string]$Index
)
$ErrorActionPreference = 'Stop'
if ($Action -eq 'help') {
    Write-Output @"
用法：.\scripts\dev-windows.ps1 <命令>
  test                 运行测试
  build                调试构建
  release              发布构建
  devices              列出输出设备
  configure <序号>      绑定 devices 列出的虚拟声卡
"@
    return
}
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
$env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT','User')
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw '需要 Visual Studio C++ 构建工具。' }
& (Join-Path $vs 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
Push-Location (Join-Path $PSScriptRoot '..')
try {
    switch ($Action) {
        test { swift test --scratch-path build }
        build { swift build --scratch-path build }
        release { swift build -c release --scratch-path build }
        devices { swift run --scratch-path build anykey-mic devices }
        configure { swift run --scratch-path build anykey-mic configure @(if ($Index) { $Index }) }
    }
    if ($LASTEXITCODE -ne 0) { throw "Swift 命令失败：$LASTEXITCODE" }
} finally { Pop-Location }
