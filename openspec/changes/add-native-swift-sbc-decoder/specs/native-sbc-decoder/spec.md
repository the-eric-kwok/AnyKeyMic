## ADDED Requirements

### Requirement: 固定 SBC 帧校验

解码器 SHALL 接收 23 字节帧：`AD 31 0C` 头加 20 字节蓝牙载荷，并校验帧长度、同步头和 CRC。解码器 SHALL 使用 16 kHz、单声道、8 子带、Loudness、bitpool 12、10 blocks 配置，输出 80 个 Int16 样本。

#### Scenario: 有效蓝牙帧

- **WHEN** 输入完整的 23 字节固定 profile 帧
- **THEN** 解码器输出 80 个 Int16 样本，并保持跨帧合成滤波器状态。

#### Scenario: 无效或截断帧

- **WHEN** 输入长度错误、同步头错误或 CRC 校验失败
- **THEN** 解码器拒绝该帧，不把压缩数据写入音频设备，并返回可诊断错误。

### Requirement: Node 解码器兼容迁移

迁移期间 SHALL 使用 `mi-sbc` 生成的 golden vectors 验证 Swift 解码器。Swift 输出 SHALL 至少匹配样本数、端序、RMS、峰值和波形相关性；最终目标是逐样本一致或仅有可解释的定点舍入误差。

### Requirement: 跨平台原生运行

最终解码路径 SHALL 在 Windows x64 和 macOS Apple Silicon 中不依赖 Node.js、N-API 或厂商 `.node` 文件。USB 原始 PCM 路径 SHALL 保持不变。
