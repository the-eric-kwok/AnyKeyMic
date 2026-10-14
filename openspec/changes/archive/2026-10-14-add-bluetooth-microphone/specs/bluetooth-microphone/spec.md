## ADDED Requirements

### Requirement: 蓝牙设备连接

程序 SHALL 识别受支持键盘的蓝牙厂商 HID 接口，并使用匹配传输类型的命令通道和报告长度。

Windows 蓝牙枚举可能无法提供可靠的 VID，程序 SHALL 以 PID `8243` 且 Usage Page `FF00` 及以上作为蓝牙厂商接口匹配条件。

#### Scenario: 蓝牙已配对并连接

- **WHEN** 操作系统枚举到受支持的蓝牙键盘接口
- **THEN** 程序建立心跳、验证和 Open 会话，并在输出及解码后端就绪后自动开麦。

### Requirement: 厂商音频解码

程序 SHALL 校验 `0x1B` 报文长度，将三个 20 字节净荷分别补入 `AD 31 0C` 帧头，解码为合计 240 个 Int16 样本。程序 MUST NOT 将压缩数据当作 PCM 播放。

#### Scenario: 完整音频报文

- **WHEN** 收到包含至少 62 字节的 `0x1B` 音频报文
- **THEN** 程序按顺序解码三个小帧并仅向已绑定虚拟声卡输出有效 PCM。

#### Scenario: 截断报文或后端失败

- **WHEN** 报文不足 62 字节、解码结果长度异常或解码后端不可用
- **THEN** 程序不输出无效音频，后端故障必须被明确报告，并释放当前会话资源。

### Requirement: 自动恢复

程序 SHALL 将蓝牙音频流视为连接存活证据，避免推流期间因心跳排队而反复断线。

#### Scenario: 蓝牙断开后重新连接

- **WHEN** 蓝牙连接中断后重新可用
- **THEN** 程序清空旧缓冲、重新建立解码及 HID 会话，并自动恢复开麦。

### Requirement: USB 兼容

程序 SHALL 保留既有 USB `0x1C` PCM 处理路径，USB 使用不得依赖蓝牙专用解码后端。

#### Scenario: USB 模式运行

- **WHEN** 键盘通过 PID `8102` 接口提供原始 PCM
- **THEN** 程序直接桥接 PCM，并继续通过现有 USB 协议测试。
