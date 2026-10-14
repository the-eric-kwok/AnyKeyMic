# 蓝牙麦克风支持

## Why

USB 桥接已通过用户实机验收。用户需要键盘通过蓝牙连接时，同样能够自动开麦、持续输出至虚拟声卡，并在重连后恢复收音。

## What Changes

- 扩展设备发现，识别 VID `248A`、PID `8243` 的蓝牙厂商接口。
- 按实际传输类型编码命令帧，避免向蓝牙接口发送 USB 长度的报文。
- 解析 `0x1B` 报文，恢复三个厂商编码小帧，经解码得到 240 个 16 kHz 单声道 Int16 样本。
- 引入明确的解码后端边界；缺失后端时停止蓝牙开麦并报告可操作错误。
- 蓝牙音频纳入状态机存活判断，并清理断线后的解码状态与音频缓冲。
- 保留 USB 原始 PCM 路径和实体虚拟音频端点绑定。

## Capabilities

### Added Capabilities

- `bluetooth-microphone`：蓝牙设备识别、音频解码与自动恢复。

## Impact

主要涉及 `Sources/CNative/native.c`、`Sources/MicCore/MicSession.swift`、`Sources/AnyKeyMic/main.swift`、新增解码后端与协议测试。不会将厂商解码器视为本项目 MIT 源码，也不将厂商二进制随源码提交。

## 状态

协议和程序实现已完成，Windows x64 Release 构建及 11 项自动化测试已通过，Windows 蓝牙实机已确认持续收音并有电平波动。蓝牙断线恢复与 macOS Apple Silicon 实机仍待验收；运行蓝牙前需要通过 `ANYKEY_MIC_SBC_MODULE` 提供用户本机的 `mi-sbc` 模块路径。
