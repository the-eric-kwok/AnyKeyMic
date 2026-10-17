# AI 键映射注入

## Why

蓝牙按住说话已验收。用户需要按住 AI 键开麦的同时一并唤起输入法的语音输入（macOS 微信输入法按住 fn、Windows 常用右 Ctrl），避免每次都要按两个键。

## What Changes

- 新增平台键码的合成注入与按键捕获后端：macOS 用 CGEvent 与 listen-only CGEventTap，Windows 用 SendInput 与 GetAsyncKeyState 轮询。
- 配置新增 `aiKeyMap` 平台键码字段，旧配置向后兼容，`configure` 重绑声卡时保留映射。
- 新增 `keymap` 子命令：交互捕获目标按键、`none` 清除、`test` 试注入一次。
- AI 键按下、松开、打字停麦、断线重连与程序退出五个路径同步注入/松开映射键，防止粘键。
- 常开（USB）模式下 AI 键边沿同样触发映射键注入，不影响持续收音。
- 注入事件归零来源进程并补聚合修饰键 flags，避免被输入法按合成事件过滤。

## Capabilities

### Added Capabilities

- `ai-key-mapping`：AI 键映射键的捕获配置、按键注入与粘键保护。

## Impact

涉及 `Sources/CNative/keyinject.c`（新增）、`Sources/CNative/native.c`、`Sources/MicCore/MicSession.swift`、新增 `Sources/MicCore/KeyNames.swift`、`Sources/AnyKeyMic/main.swift`、`Package.swift` 与登录启动脚本。macOS 注入需要辅助功能权限，捕获沿用输入监控；Windows 无需额外权限，fn 键因无标准 VK 码不可用。

## 状态

实现与测试已完成：23 项协议与键码单元测试通过（3 项既有 golden 数据缺失与本变更无关）；macOS 实机已验收——keymap 捕获 fn、注入事件唤起微信输入法语音浮层（窗口列表检测到 200×130 置顶浮层），用户已按 AI 键完成端到端验收。Windows 分支代码就绪，待 Windows 实机构建验证。
