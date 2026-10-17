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
anykey-mic keymap
anykey-mic run --seconds 30
anykey-mic run
```

`2` 只是示例，必须换成设备列表中 CABLE Input／BlackHole 的序号。配置保存稳定端点 ID，而不是默认设备别名。虚拟声卡缺失时等待恢复，绝不回退系统扬声器。接收软件选择 CABLE Output／BlackHole 作为输入，系统输出继续使用扬声器或耳机，关闭“侦听此设备”。

`run` 自动握手并恢复断线；Ctrl+C 停止。日志只记录连接、开关麦与音量统计（仅在有音频的时段输出），不保存音频。短时测试成功后，才启用登录启动。锁屏不影响运行，睡眠期间不会收音，唤醒后重新建立会话。

### 跨平台吞字诊断

诊断日志会同时记录平台名、进程号、单调时钟、HID 报文类型与间隔、AI 键边沿、映射键注入结果、发送的麦克风命令、SBC 解码耗时、音频设备停止／重路由事件，以及每十秒的样本统计。日志不保存音频内容；键盘报文只记录用于判断按键状态的前 9 字节十六进制摘要。

Windows 运行 `dist\\anykey-mic.exe run --seconds 60`，日志在 `%LOCALAPPDATA%\\AnyKeyMic\\run.log`；macOS 运行 `anykey-mic run --seconds 60`，日志在 `~/Library/Logs/AnyKeyMic/run.log`。两端必须使用同一次构建产生的程序，并在日志中确认 `session_open`、`hid_rx`、`key_inject` 和 `stats` 均存在后再比较吞字现象。若 Windows 显示 `键盘厂商接口数：0`，说明尚未进入可比的设备运行阶段。比较蓝牙常开麦行为时，Windows 使用 `run --seconds 60 --always-on`，并确认日志中的 `session_open` 为 `mode=always_on`。

### 开麦与停麦

USB 连接下麦克风常开。蓝牙连接下采用按住说话，因为持续推流会占满蓝牙带宽，导致键盘丢字：

- **开麦**：按住键盘上的 AI 键。
- **停麦方式一**：松开 AI 键。日志记为 `AI 键松开：停麦。`
- **停麦方式二**：开麦期间按下其他任意键（含右 Ctrl 等修饰键）。推流时 AI 键的松开报告可能丢失，开始打字即视为已松开。日志记为 `按键停麦，报告：…`，附触发停麦的键盘报告。

服务启动和断线重连后均为停麦状态。需要输入法语音输入与开麦一并触发时，用下方「AI 键映射」配置，不要依赖单独按热键。

### AI 键映射

按住 AI 键开麦的同时，桥接程序会向系统合成注入一个映射键，把输入法的语音输入热键设为该键后，只按 AI 键即可一并唤起语音输入。运行 `anykey-mic keymap` 交互捕获目标按键（macOS 常用 fn 键，Windows 常用右 Ctrl），按 Esc 取消；`anykey-mic keymap test` 会注入一次按下与松开，用于立刻验证输入法是否响应；`anykey-mic keymap none` 清除映射。映射以平台键码存入 config.json，`configure` 重新绑定声卡时会保留。

- 松开 AI 键或打字停麦时同步松开映射键；断线重连和程序退出也会自动松开，不会粘键。
- 蓝牙按住说话与 USB 常开两种模式都生效：常开模式下按 AI 键只注入映射键，不影响持续收音。
- macOS 注入需要「系统设置 › 隐私与安全性 › 辅助功能」权限（捕获沿用「输入监控」），缺失时启动日志会提示；Windows 无需额外权限。
- fn 键在 Windows 上没有标准键码，无法捕获或注入，属系统限制。macOS 听写若设为「按两次 fn」，需快速按两次 AI 键触发。

蓝牙解码器已经内置在 Swift 主程序中，运行时不需要 Node.js、N-API、厂商 `.node` 文件或额外环境变量。历史 golden 数据只用于开发期回归测试，保存在本机 `.sbc-golden` 目录，默认被 Git 忽略。



## 登录启动

Windows：先运行 `scripts/package-windows.ps1`，再使用管理脚本安装当前用户登录自启：

```powershell
.\scripts\login-windows.ps1 devices
.\scripts\login-windows.ps1 configure 2
.\scripts\login-windows.ps1 install
.\scripts\login-windows.ps1 status
.\scripts\login-windows.ps1 start
.\scripts\login-windows.ps1 stop
.\scripts\login-windows.ps1 restart
.\scripts\login-windows.ps1 uninstall
```

脚本通过当前用户的启动文件夹创建启动项，并以隐藏窗口运行。运行日志位于 `%LOCALAPPDATA%/AnyKeyMic/run.log`。也兼容旧用法 `-Remove`。首次测试可直接运行 `dist/anykey-mic.exe run`。

macOS：

```shell
sh scripts/login-macos.sh devices
sh scripts/login-macos.sh configure 1
sh scripts/login-macos.sh install
sh scripts/login-macos.sh status
sh scripts/login-macos.sh start
sh scripts/login-macos.sh stop
sh scripts/login-macos.sh restart
sh scripts/login-macos.sh uninstall
```

脚本安装并管理当前用户 LaunchAgent。`uninstall` 会保留配置、运行文件和日志。日志位于 `~/Library/Logs/AnyKeyMic/run.log`。所有脚本不带参数时输出帮助，`devices`／`configure`／`keymap` 直接转发给主程序。

后台服务需要「输入监控」权限才能打开键盘，否则日志会反复出现 `Cannot open selected HID interface`。配置了 AI 键映射时还需要「辅助功能」权限，缺失时启动日志会给出提示。临时签名的程序每次重新安装后，都要在「系统设置 › 隐私与安全性 › 输入监控」里重新允许；安装时若把 `ANYKEYMIC_SIGN_IDENTITY` 设为钥匙串中的证书名称（可用 `security find-identity -v -p codesigning` 查询），重新构建后授权仍然有效。

以上均为当前用户登录自启，不是系统级服务，不需要管理员权限。Windows 卸载会强制停止匹配安装路径的进程，无法保证停麦命令送达；macOS 停止会卸载当前 LaunchAgent，但保留登录启动配置，下次登录仍会启动。安装会立即启动程序，请先完成 configure 和短时收音测试。Windows 启动项依赖当前仓库中的 scripts 和 dist，移动目录后需要重新安装；更新打包前先执行 stop。

暂未配置日志轮转，长期部署前需要留意日志大小。不要同时运行两个桥接程序。

## 验证范围

协议单元测试覆盖握手、畸形报文、PCM 小端转换和重连。实机还需要验证持续收音、USB 拔插、睡眠唤醒、虚拟设备消失与恢复。仅编译或枚举成功不代表这些硬件行为已经通过。

## 来源与限制

协议依据 anykey-ai 固定提交 `ea7116d32197f4bf2772d2ed20af8f4a1cdcc43b` 的 `src/main/kb-session.js`、`src/main/mic.js` 和 `docs/protocol.md`。保留其 MIT 版权声明。没有复制其 `vendor/mi-hid` 或 `vendor/mi-sbc` 二进制。详见 THIRD_PARTY.md。
