#requires -Version 7
param([string]$Binary = 'dist/anykey-mic.exe')
$ErrorActionPreference = 'Stop'
$binaryPath = (Resolve-Path -LiteralPath $Binary).Path
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path $projectRoot ('build/服务管理 smoke ' + [Guid]::NewGuid().ToString('N'))
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'AnyKeyMic.lnk'
$oldLocalAppData = $env:LOCALAPPDATA
$backupLink = Join-Path $testRoot 'original.lnk'
$hadShortcut = Test-Path -LiteralPath $startupLink
$testActive = $false

function Invoke-Mic([string[]]$Arguments, [int]$Expected = 0, [string]$Executable = $binaryPath) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(20000)) { throw "命令超时：$Arguments" }
        if (![Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) {
            throw "命令已退出，但输出管道未关闭：$Arguments"
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne $Expected) { throw "命令 $Arguments 退出码 $($process.ExitCode)，预期 $Expected。`n$output" }
        return $output
    } finally { $process.Dispose() }
}

function Assert-Contains([string]$Text, [string]$Value) {
    if (!$Text.Contains($Value)) { throw "缺少预期内容「$Value」：`n$Text" }
}

try {
    # 旧版不能通过新控制协议查询，单独检查其互斥体。
    $legacy = $null
    try { $legacy = [Threading.Mutex]::OpenExisting('Local\AnyKeyMic-USB') }
    catch [Threading.WaitHandleCannotBeOpenedException] { }
    if ($legacy) { $legacy.Dispose(); throw '请先停止现有 AnyKeyMic 实例。' }
    Assert-Contains (Invoke-Mic @('status')) '正在运行：否'
    $bytes = [IO.File]::ReadAllBytes($binaryPath)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt16($bytes, $peOffset + 24 + 68) -ne 2) { throw '发布产物不是无控制台窗口的 Windows GUI 子系统。' }
    [void](New-Item -ItemType Directory -Path $testRoot)
    if ($hadShortcut) { Copy-Item -LiteralPath $startupLink -Destination $backupLink }
    $env:LOCALAPPDATA = $testRoot
    $testActive = $true
    $configDir = Join-Path $testRoot 'AnyKeyMic'
    $installed = Join-Path $configDir 'bin/anykey-mic.exe'
    $config = Join-Path $configDir 'config.json'
    $log = Join-Path $configDir 'run.log'

    Assert-Contains (Invoke-Mic @('help')) 'install'
    Assert-Contains (Invoke-Mic @('unknown-command') 1) '未知命令'
    Assert-Contains (Invoke-Mic @('status', 'unexpected') 1) '不接受额外参数'
    Assert-Contains (Invoke-Mic @('install') 1) '配置缺失或无效'
    [void](New-Item -ItemType Directory -Path $configDir)
    [IO.File]::WriteAllText($config, '{broken')
    Assert-Contains (Invoke-Mic @('install') 1) '配置缺失或无效'
    # 不存在的端点使程序等待，不打开 HID、不收音、不注入按键。
    [IO.File]::WriteAllText($config, '{"outputID":"anykey-mic-service-smoke-missing-endpoint","outputName":"CABLE Input"}')
    Assert-Contains (Invoke-Mic @('install')) '已安装并启动'
    if (!(Test-Path -LiteralPath (Join-Path $configDir 'bin/swiftCore.dll'))) { throw '未复制 Swift 运行库。' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupLink)
    if ($shortcut.TargetPath -ne $installed -or $shortcut.Arguments -ne 'run --background') { throw '登录启动项没有直接指向安装后的程序。' }
    $state = Invoke-Mic @('status')
    Assert-Contains $state '已安装：是'
    Assert-Contains $state '正在运行：是'
    Assert-Contains (Invoke-Mic @('start')) '后台进程已启动'
    $instances = @(Get-Process anykey-mic -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $installed })
    if ($instances.Count -ne 1 -or $instances[0].MainWindowHandle -ne 0) { throw '重复启动或创建了主窗口。' }
    Assert-Contains (Invoke-Mic @('run', '--seconds', '1') 1) '已有 AnyKeyMic'
    Assert-Contains (Invoke-Mic @('run', '--background', '--seconds', '1') 1) '已有 AnyKeyMic'
    $firstPid = $instances[0].Id
    Assert-Contains (Invoke-Mic @('restart')) '后台进程已重启'
    $instances = @(Get-Process anykey-mic | Where-Object { $_.Path -eq $installed })
    if ($instances.Count -ne 1 -or $instances[0].Id -eq $firstPid) { throw 'restart 没有替换进程。' }
    Assert-Contains (Invoke-Mic @('install')) '已安装并启动'
    Assert-Contains (Invoke-Mic @('install') 0 $installed) '已安装并启动'
    # 登录启动可能不继承安装工具的目录重定向，安装后的 CLI 应使用相邻配置。
    try {
        $env:LOCALAPPDATA = Join-Path $testRoot 'different-environment'
        Assert-Contains (Invoke-Mic @('status') 0 $installed) '已安装：是'
        Assert-Contains (Invoke-Mic @('start') 0 $installed) '后台进程已启动'
    } finally { $env:LOCALAPPDATA = $testRoot }
    Assert-Contains (Invoke-Mic @('stop')) '已停止运行'
    Assert-Contains (Invoke-Mic @('stop')) '已停止运行'
    $state = Invoke-Mic @('status')
    Assert-Contains $state '已安装：是'
    Assert-Contains $state '正在运行：否'
    $text = [IO.File]::ReadAllText($log)
    Assert-Contains $text '桥接已停止。'
    if ($text.Contains('已有 AnyKeyMic')) { throw '重复后台入口写入了活动实例的日志。' }
    if ([regex]::Matches($text, 'process_start').Count -lt 4) { throw '后台日志未追加保存。' }

    # 模拟快捷方式直接启动，不依赖 start 命令提供的日志重定向。
    $info = [Diagnostics.ProcessStartInfo]::new($installed)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.Arguments = 'run --background --seconds 10'
    $direct = [Diagnostics.Process]::Start($info)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            Start-Sleep -Milliseconds 100
            $state = Invoke-Mic @('status')
        } while (!$state.Contains('正在运行：是') -and [DateTime]::UtcNow -lt $deadline)
        Assert-Contains $state '正在运行：是'
        Assert-Contains (Invoke-Mic @('uninstall')) '已取消登录自启'
        if (!$direct.WaitForExit(5000)) { throw '直接启动的后台进程未正常退出。' }
    } finally { $direct.Dispose() }
    Assert-Contains (Invoke-Mic @('uninstall')) '已取消登录自启'
    $state = Invoke-Mic @('status')
    Assert-Contains $state '已安装：否'
    Assert-Contains $state '正在运行：否'
    foreach ($path in @($installed, $config, $log)) {
        if (!(Test-Path -LiteralPath $path)) { throw "卸载错误删除了保留文件：$path" }
    }
    Assert-Contains (Invoke-Mic @('start') 1) '请先执行 install'
    Write-Output "管理功能验证通过。测试产物：$testRoot"
} finally {
    if ($testActive) {
        try { [void](Invoke-Mic @('stop')) }
        finally {
            if ($hadShortcut) { Copy-Item -LiteralPath $backupLink -Destination $startupLink -Force }
            elseif (Test-Path -LiteralPath $startupLink) { Remove-Item -LiteralPath $startupLink }
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }
}
