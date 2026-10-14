# 标准 SBC 兼容性探测

## 基准数据

使用 Windows x64 实机和历史 `mi-sbc` oracle 采集了 306 个蓝牙帧。每个 `0x1B` 报文拆为 3 个 23 字节适配帧，每帧输出 80 个 Int16 样本。基准文件只保存在本机 `.sbc-golden` 目录，未加入仓库。

## 标准解码器探测

系统 FFmpeg 的 `sbc` 解码器无法直接解码当前固定的 23 字节输入帧，因此项目实现了固定 profile 的专用 Swift 解码器：16 kHz、单声道、8 子带、Loudness、bitpool 12、10 blocks。

## Swift 解码结果

Swift 已完成纯位流解析、反量化和 8 子带合成滤波器，并通过 306 个本机数据包中的 918 个固定帧解析验证。使用 30 个 golden packet 与历史 `mi-sbc` PCM 对比：

- 波形相关性：`0.9999888`
- RMS 比例：`0.999946`
- 输出样本数：一致

运行时已切换为纯 Swift 解码，不再加载 Node.js、N-API、`mi-sbc.node` 或任何厂商解码器。golden 数据仅作为开发期回归夹具保留。

## 验收状态

Windows x64 USB 和蓝牙路径已完成实机验收，蓝牙断开并重新连接后能够恢复收音。macOS Apple Silicon 的构建和实机验证仍待完成。
