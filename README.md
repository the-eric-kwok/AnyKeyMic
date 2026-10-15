# AnyKeyMic

使用 Swift 和轻量 C 适配层，把 RK R87 Pro AI 的 USB 麦克风持续送入虚拟声卡。无 Electron、Node.js 或图形界面。

蓝牙和 USB 路径均使用纯 Swift／C 原生实现，不依赖 Node.js、Electron 或厂商解码器。macOS 代码已提供，需要在 Apple Silicon 实机编译与验证。

## 构建

Windows x64 需要 Swift 6 工具链、Visual Studio C++ 构建工具和 Windows SDK。macOS 需要 Swift 6／Xcode 命令行工具。依赖源码已固定在仓库中，构建不会执行 git 或下载 Swift 包。

```shell
swift test --scratch-path build
swift build -c release --scratch-path build
```

HIDAPI 0.14.0 负责非独占 HID，miniaudio 0.11.21 负责 WASAPI／Core Audio 输出和格式转换。协议状态机由 Swift 实现。程序固定请求 16 kHz 单声道 Int16，设备所需重采样由音频后端完成。

## 首次运行

先退出 AnyKey AI 和官方 RK-AI，避免多个进程争用设备。安装 VB-CABLE（Windows）或 BlackHole（macOS）。运行产物位于 `build/release`，Windows 可用 `swift build -c release --scratch-path build --show-bin-path` 获取准确目录。

```shell
anykey-mic devices
anykey-mic configure 2
anykey-mic run --seconds 30
anykey-mic run
```

`2` 只是示例，必须换成设备列表中 CABLE Input／BlackHole 的序号。配置保存稳定端点 ID，而不是默认设备别名。虚拟声卡缺失时等待恢复，绝不回退系统扬声器。接收软件选择 CABLE Output／BlackHole 作为输入，系统输出继续使用扬声器或耳机，关闭“侦听此设备”。

`run` 自动握手、开麦并恢复断线；Ctrl+C 停止。日志只记录连接与音量统计，不保存音频。短时测试成功后，才启用登录启动。锁屏不影响运行，睡眠期间不会收音，唤醒后重新建立会话。

蓝牙解码器已经内置在 Swift 主程序中，运行时不需要 Node.js、N-API、厂商 `.node` 文件或额外环境变量。历史 golden 数据只用于开发期回归测试，保存在本机 `.sbc-golden` 目录，默认被 Git 忽略。



## 登录启动

Windows：先运行 `scripts/package-windows.ps1`，再运行 `scripts/login-windows.ps1`。脚本创建当前用户启动项；下次登录以隐藏窗口启动。移除使用 `scripts/login-windows.ps1 -Remove`。运行日志位于 `%LOCALAPPDATA%/AnyKeyMic/run.log`。首次测试可直接运行 `dist/anykey-mic.exe run`。隐藏实例可通过任务管理器结束；强制终止不能保证停麦命令送达。

macOS：构建并完成 `configure` 后运行 `sh scripts/login-macos.sh`，安装并启动当前用户 LaunchAgent。移除使用 `sh scripts/login-macos.sh --remove`。日志位于 `~/Library/Logs/AnyKeyMic/run.log`。

暂未配置日志轮转，长期部署前需要留意日志大小。不要同时运行两个桥接程序。

## 验证范围

协议单元测试覆盖握手、畸形报文、PCM 小端转换和重连。实机还需要验证持续收音、USB 拔插、睡眠唤醒、虚拟设备消失与恢复。仅编译或枚举成功不代表这些硬件行为已经通过。

## 来源与限制

协议依据 anykey-ai 固定提交 `ea7116d32197f4bf2772d2ed20af8f4a1cdcc43b` 的 `src/main/kb-session.js`、`src/main/mic.js` 和 `docs/protocol.md`。保留其 MIT 版权声明。没有复制其 `vendor/mi-hid` 或 `vendor/mi-sbc` 二进制。详见 THIRD_PARTY.md。


