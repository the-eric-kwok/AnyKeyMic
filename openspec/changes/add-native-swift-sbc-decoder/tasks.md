## 实施与验证

- [x] 定义 23 字节固定帧和 80 样本输出的基准向量格式。
- [x] 从现有 `mi-sbc` worker 增加仅本机启用的 golden vector 导出。
- [x] 在 Swift 中增加 `SBCDecoder` 抽象和固定 profile 校验。
- [x] 探测公开 SBC 实现，确认通用解码器无法直接接受当前固定帧。
- [x] 用 306 个本机 golden packet 验证 918 个固定帧可以完成 Swift 位流解析和 80 样本子带输出。
- [x] 建立独立的 Swift 8 子带合成滤波器状态，并覆盖零输入、复位和连续帧长度测试。
- [x] 用 30 个 golden packet 对比 `mi-sbc` PCM：相关系数 0.9999888，RMS 比例 0.999946，样本数一致。
- [x] 实现纯 Swift bit reader、反量化和第一版 8 子带合成滤波器；PCM 误差仍待 golden 对比。
- [x] 增加固定帧 CRC 失败、截断帧和连续 packet 拆帧测试；CRC 规则仍需与厂商真实帧进一步校准。
- [x] 增加丢帧和重连测试。
- [x] Windows x64 实机验收通过；macOS Apple Silicon 待实机验证。
- [x] 删除 Node worker、Node 环境变量和厂商解码器依赖，运行路径改为纯 Swift。


