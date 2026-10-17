## ADDED Requirements

### Requirement: 映射键捕获配置

程序 SHALL 提供 `keymap` 子命令交互捕获用户按下的物理按键，并以平台键码保存至 config.json；`keymap none` 清除映射，`keymap test` 注入一次按下与松开用于验证。旧配置文件缺省该字段时 SHALL 视为未映射，`configure` 重新绑定声卡 SHALL 保留已配置的映射。

#### Scenario: 捕获 fn 键

- **WHEN** 用户运行 `keymap` 并按下 fn 键
- **THEN** 程序记录键码 63 并写回 config.json，同时保留声卡绑定字段。

#### Scenario: Esc 取消

- **WHEN** 用户在捕获等待期间按下 Esc
- **THEN** 程序不修改现有配置并提示已取消。

### Requirement: 按键注入同步

程序 SHALL 在 AI 键按下边沿注入映射键按下，在松开边沿、打字停麦、会话重连与程序退出时注入松开。两种收音模式 SHALL 一致生效：蓝牙按住说话与开麦同步，USB 常开模式下仅随 AI 键边沿注入且不影响持续收音。

#### Scenario: 蓝牙按住说话

- **WHEN** 用户按住 AI 键随后松开
- **THEN** 程序在按下时注入映射键按下并在松开时注入松开，日志记录两个边沿。

#### Scenario: 打字停麦

- **WHEN** 开麦期间用户按下其他键触发停麦
- **THEN** 程序立即注入映射键松开，避免粘键。

#### Scenario: 会话重连

- **WHEN** HID 或音频会话异常重建
- **THEN** 程序在重建前注入映射键松开，恢复后待 AI 键重新按下才再次注入。

### Requirement: 注入事件真实性

注入的修饰键事件 SHALL 携带聚合修饰键 flags 并归零来源进程字段，使输入法与系统将其视为硬件事件；注入前 SHALL 预检权限并在缺失时报告可操作错误且不影响收音。

#### Scenario: 微信输入法唤起

- **WHEN** 映射键为 fn 且用户按住 AI 键
- **THEN** 输入法的语音输入浮层被唤起，松开 AI 键后随注入松开而结束。

#### Scenario: 权限缺失

- **WHEN** macOS 未授予辅助功能权限
- **THEN** 程序记录一次可操作的授权提示，收音桥接不受影响。
