# 原生 Swift SBC 解码器

## Why

历史蓝牙实现曾通过 Node.js 辅助进程加载厂商 `mi-sbc.node`，增加了运行时依赖和部署复杂度。本变更已经用独立 Swift 解码器替代该路径。

现有帧格式已经确认是固定参数的 SBC 变体：`AD 31 0C` 头、16 kHz、单声道、8 子带、Loudness、bitpool 12、10 个 block，每帧输出 80 个 Int16 样本。目标是在保持实机输出一致的前提下，用 Swift 解码器替换 Node 辅助进程。

公开专利 CN108882216A 的实施例给出了相同的固定参数和 20 字节压缩帧结构，可作为公开协议资料；项目不会复制厂商二进制或其实现代码。

## What Changes

- 建立 `mi-sbc` 黑盒基准向量格式，记录 23 字节输入帧、解码样本数和 160 字节 PCM 输出。
- 增加固定 SBC profile 的 Swift 接口和输入校验。
- 先验证公开 SBC 实现是否能通过适配支持 10 block 配置。
- 若标准实现不兼容，实现不依赖 Node 的专用 Swift 解码器。
- 在逐帧、连续帧、CRC 错误、丢帧和断线重连测试通过后使用纯 Swift 解码路径。
- 运行时不保留 Node 解码回退路径，也不提交或分发厂商二进制；历史 oracle 仅用于生成 golden 测试数据。

## Impact

主要涉及 `Sources/MicCore`、`Sources/AnyKeyMic`、蓝牙测试夹具和构建脚本。USB PCM 路径不变。解码器必须同时支持 Windows x64 和 macOS Apple Silicon，并且音频循环中不得产生不受控的堆分配。

## 调查边界

厂商 `.node` 只作为黑盒 oracle 生成基准输出。除非标准 SBC 适配确认失败，否则不分析其机器码；若确实需要深入分析，必须先确认许可证和可接受的 clean-room 边界。


