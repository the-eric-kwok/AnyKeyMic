$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    swift build -c release
    if ($LASTEXITCODE -ne 0) { throw 'Swift 构建失败。' }
    $binPath = (swift build -c release --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw '无法确定产物目录。' }
    New-Item -ItemType Directory -Force -Path dist | Out-Null
    Copy-Item -LiteralPath (Join-Path $binPath 'anykey-mic.exe') -Destination dist
    # Swift 安装器把运行时位置加入 PATH；复制对应 DLL，避免目标机器依赖全局安装。
    $runtimeDirs = $env:Path.Split(';') | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'swiftCore.dll')) }
    if (!$runtimeDirs) { throw '未找到 swiftCore.dll，请在已加载 Swift 环境的终端运行。' }
    foreach ($directory in $runtimeDirs) {
        Get-ChildItem -LiteralPath $directory -Filter '*.dll' | Copy-Item -Destination dist
    }
    Copy-Item -LiteralPath LICENSE,THIRD_PARTY.md -Destination dist
    Write-Output '已生成 dist；Windows 目标机仍需 Microsoft VC++ 运行库。'
} finally { Pop-Location }
