param([string]$OutputDirectory = 'dist')
$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    swift build -c release --scratch-path build
    if ($LASTEXITCODE -ne 0) { throw 'Swift build failed.' }
    $binPath = (swift build -c release --scratch-path build --show-bin-path | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot determine binary directory.' }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    Copy-Item -LiteralPath (Join-Path $binPath 'anykey-mic.exe') -Destination $OutputDirectory
    $runtimeDirs = $env:Path.Split(';') | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'swiftCore.dll')) }
    if (!$runtimeDirs) { throw 'swiftCore.dll was not found.' }
    foreach ($directory in $runtimeDirs) {
        Get-ChildItem -LiteralPath $directory -Filter '*.dll' | Copy-Item -Destination $OutputDirectory
    }
    Copy-Item -LiteralPath LICENSE,THIRD_PARTY.md -Destination $OutputDirectory
    Write-Output "Package created in $OutputDirectory."
} finally { Pop-Location }
