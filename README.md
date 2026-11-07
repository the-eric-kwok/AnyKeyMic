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

前台 `run` 将日志写到标准错误，可以用 `anykey-mic run --seconds 60 2> diagnostic.log` 保存诊断日志。后台 `start` 的日志在 Windows 的 `%LOCALAPPDATA%/AnyKeyMic/run.log` 或 macOS 的 `~/Library/Logs/AnyKeyMic/run.log`，`status` 会显示完整路径。两端应使用同一版本源码构建，并在日志中确认 `session_open`、`hid_rx`、`key_inject` 和 `stats` 均存在后再比较吞字现象。若 Windows 显示 `键盘厂商接口数：0`，说明尚未进入可比的设备运行阶段。比较蓝牙常开麦行为时，使用 `run --seconds 60 --always-on`，并确认日志中的 `session_open` 为 `mode=always_on`。

### 开麦与停麦

用 `mode` 查询或保存开麦方式，前台和后台程序都会自动重读配置：

```shell
anykey-mic mode
anykey-mic mode always-on
anykey-mic mode push-to-talk
anykey-mic mode auto
```

`always-on` 为常开麦，`push-to-talk` 为按住 AI 键说话，两种选择都适用于 USB 和蓝牙。`auto` 是默认值，旧配置缺少模式字段时也使用它：Windows 的 USB 和蓝牙均常开麦；macOS 的 USB 常开麦、蓝牙按键开麦。蓝牙常开会持续占用带宽，可能导致键盘丢字。按键开麦模式的操作如下：

- **开麦**：按住键盘上的 AI 键。
- **停麦方式一**：松开 AI 键。日志记为 `AI 键松开：停麦。`
- **停麦方式二**：开麦期间按下其他任意键（含右 Ctrl 等修饰键）。推流时 AI 键的松开报告可能丢失，开始打字即视为已松开。日志记为 `按键停麦，报告：…`，附触发停麦的键盘报告。

按键开麦模式在启动和断线重连后均为停麦状态；暂停时不再输出收到的 SBC 或 PCM 音频。常开模式则会自动开始推流。`run --always-on` 或 `run --push-to-talk` 只覆盖本次运行，不修改保存的模式；两者不能同时指定。需要输入法语音输入与开麦一并触发时，用下方「AI 键映射」配置。

### AI 键映射

按住 AI 键开麦的同时，桥接程序会向系统合成注入一个映射键，把输入法的语音输入热键设为该键后，只按 AI 键即可一并唤起语音输入。运行 `anykey-mic keymap` 交互捕获目标按键（macOS 常用 fn 键，Windows 常用右 Ctrl），按 Esc 取消；`keymap status` 查询当前映射和配置路径，`keymap test` 注入一次按下与松开，`keymap none` 清除映射。也可以用 `keymap <十进制键码>` 直接设置，例如 Windows 的右 Ctrl 是 `keymap 163`，macOS 的 fn 是 `keymap 63`。

映射和模式写入同一份 `config.json`，`configure` 重绑声卡时保留两者。运行中的新版约每半秒检查配置变化，先结束旧会话并松开映射键，再使用新配置建立会话，无需手动重启；暂时无法读取或解析配置时继续使用最后生效的配置。`status` 会显示保存的模式、映射及配置路径，日志的 `settings_applied` 表示已应用。

Windows 从发布目录执行配置命令时会跟随原生登录启动项，使用已安装程序的配置，避免不同终端的 AppData 重定向导致配置分叉。需要独立配置或运行测试时，可设置 `ANYKEYMIC_CONFIG` 为配置文件的完整路径。

- 松开 AI 键或打字停麦时同步松开映射键；断线重连和程序退出也会自动松开，不会粘键。
- 常开和按键开麦模式均支持映射：常开模式下按 AI 键只注入映射键，不影响持续收音。
- macOS 注入需要「系统设置 › 隐私与安全性 › 辅助功能」权限（捕获沿用「输入监控」），缺失时启动日志会提示；Windows 无需额外权限。
- fn 键在 Windows 上没有标准键码，无法捕获或注入，属系统限制。macOS 听写若设为「按两次 fn」，需快速按两次 AI 键触发。

蓝牙解码器已经内置在 Swift 主程序中，运行时不需要 Node.js、N-API、厂商 `.node` 文件或额外环境变量。历史 golden 数据只用于开发期回归测试，保存在本机 `.sbc-golden` 目录，默认被 Git 忽略。



## 登录启动

两个平台均由 `anykey-mic` 自身完成安装、登录自启注册和后台进程管理，不再需要运行管理脚本。先完成虚拟声卡配置和短时收音测试，再执行 `install`。

Windows：在 Swift／Visual Studio 开发环境中运行 `scripts/package-windows.ps1`，从完整的 `dist` 发布目录安装：

```powershell
.\dist\anykey-mic.exe devices | Out-Host
.\dist\anykey-mic.exe configure 2 | Out-Host
.\dist\anykey-mic.exe install | Out-Host
.\dist\anykey-mic.exe status | Out-Host
```

旧程序占用 `dist` 时，可以用 `scripts/package-windows.ps1 -OutputDirectory build/service-package` 输出到独立目录；安装新版前仍需先退出旧实例。

安装会将程序及同目录 DLL 复制到 `%LOCALAPPDATA%/AnyKeyMic/bin`，并通过原生 Windows API 创建当前用户启动文件夹中的 `AnyKeyMic.lnk`，直接启动该目录下的程序。旧版同名启动项会被替换，之后移动或删除源码仓库不影响运行。Swift 运行库仍需随发布目录分发，不能只复制一个 exe。

若安装工具受到 Windows 应用目录重定向，登录项会使用解析后的实际安装路径。安装后的程序始终读取 `bin` 上一级的 `config.json`，不依赖登录时的环境变量；`status` 显示实际程序与日志路径。

为保证登录启动不闪控制台窗口，Windows 程序使用 GUI 子系统，前台命令会附加调用它的终端并保留重定向。交互式 PowerShell 建议加 `| Out-Host`，确保等待命令完成；交互式 cmd 可用 `start "" /wait anykey-mic.exe <命令>`。脚本或其他程序调用时应等待进程退出并检查退出码。

macOS：

```shell
swift build -c release --scratch-path build
build/release/anykey-mic devices
build/release/anykey-mic configure 1
build/release/anykey-mic install
build/release/anykey-mic status
```

安装会复制当前二进制到 `~/Library/Application Support/AnyKeyMic/anykey-mic`，生成 `~/Library/LaunchAgents/local.anykeymic.plist`，通过系统 `launchctl` 管理当前用户 LaunchAgent。构建与签名属于发布流程，`install` 不编译源码、不调用签名工具。需要稳定签名身份时，发布前执行 `codesign -f -s "证书名称" -i local.anykeymic <构建产物路径>`，再用该产物安装。

macOS 后台服务需要「输入监控」权限才能打开键盘，否则日志会反复出现 `Cannot open selected HID interface`。配置了 AI 键映射时还需要「辅助功能」权限。请对固定安装路径中的程序授权；临时签名的程序更新后通常需要重新允许，使用稳定签名身份可减少重复授权。

两端统一支持以下命令，可以从发布目录或固定安装目录调用：

| 命令 | 行为 |
| --- | --- |
| `install` | 安装或更新当前构建，注册登录自启并立即启动；要求已有有效配置 |
| `start` | 启动已安装程序，重复调用不创建第二个实例 |
| `stop` | 请求退出并等待完成，保留登录自启，下次登录仍会运行 |
| `restart` | 停止后重新启动；新版配置变更也会在运行中自动应用 |
| `status` | 显示安装状态、运行状态、程序及日志路径 |
| `uninstall` | 取消登录自启并停止，保留程序、配置与日志 |

以上均为当前用户登录自启，不需要管理员权限，也不会注册系统级 Windows Service 或 macOS LaunchDaemon。后台使用内部参数 `run --background`；正常使用请通过 `start` 管理。macOS 由 launchd 在异常退出后重启，Windows 启动项仅在登录时启动，异常退出后需执行 `start`。

Windows 使用命名事件通知当前用户、当前会话的 AnyKeyMic 实例退出，支持正常停麦与释放映射键，也会停止同会话中手动运行的新版 `run`。macOS 使用 `launchctl bootout` 停止受管理的实例，手动运行的 `run` 仍需 Ctrl+C。停止超时会报告错误，不主动强杀。升级前请先退出旧版进程；旧版 Windows 不支持退出通知，新版检测到旧实例会拒绝并行运行。已有旧版 macOS LaunchAgent 会在安装时卸载并更新。

暂未配置日志轮转，长期部署前需要留意日志大小。不要同时运行两个桥接程序。

## 验证范围

协议单元测试覆盖握手、畸形报文、PCM 小端转换和重连。实机还需要验证持续收音、USB 拔插、睡眠唤醒、虚拟设备消失与恢复。仅编译或枚举成功不代表这些硬件行为已经通过。

Windows 管理功能回归需要 PowerShell 7，可运行 `pwsh -File scripts/test-service-windows.ps1 -Binary dist/anykey-mic.exe`。测试使用仓库内隔离配置和不存在的音频端点，不采集音频；会暂时替换当前用户的同名启动项，退出时恢复。测试前必须停止其他 AnyKeyMic 实例。覆盖无配置拒绝安装、无效参数、完整安装、重复启停、更新安装、日志追加、直接登录入口和卸载保留数据。macOS 仍需在实机验证编译、LaunchAgent 生命周期及隐私授权。

该回归同时检查模式与映射保存、字段保留和后台自动应用。`Tests/CNativeTests/keyinject_windows_tests.c` 使用桩替换桌面输入 API，可在 Visual Studio 开发环境中用 `clang-cl /MD /W4 /I Sources/CNative/include Tests/CNativeTests/keyinject_windows_tests.c /Fobuild/keyinject_windows_tests.obj /Febuild/keyinject_windows_tests.exe` 编译并运行，不会向桌面发送按键。

## 来源与限制

协议依据 anykey-ai 固定提交 `ea7116d32197f4bf2772d2ed20af8f4a1cdcc43b` 的 `src/main/kb-session.js`、`src/main/mic.js` 和 `docs/protocol.md`。保留其 MIT 版权声明。没有复制其 `vendor/mi-hid` 或 `vendor/mi-sbc` 二进制。详见 THIRD_PARTY.md。
