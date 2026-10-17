import Foundation

public struct Command: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(code: UInt8, payload: [UInt8] = []) {
        precondition(payload.count <= 56)
        let frame = [UInt8(0x05), 0xff, 0xf1, 0xfe, 0xc0, code, UInt8(payload.count)] + payload + [0xef]
        bytes = frame + Array(repeating: 0, count: 64 - frame.count)
    }

    /// 保留 USB 默认编码，仅在发送时按 HID 通道与报告长度调整。
    public func encoded(channel: UInt8, reportLength: Int) -> [UInt8]? {
        guard (channel == 0xf1 && (reportLength == 62 || reportLength == 64)) ||
              (channel == 0xf0 && reportLength == 64),
              8 + Int(bytes[6]) <= reportLength else { return nil }
        var report = Array(bytes.prefix(reportLength))
        report[2] = channel
        return report
    }
}

public enum MicProtocol {
    /// 蓝牙报告包含两字节报告头与三个省略固定帧头的 20 字节音频块。
    public static func bluetoothFrames(_ bytes: [UInt8]) -> [[UInt8]]? {
        guard bytes.count >= 62, bytes[0] == 0x1b else { return nil }
        return stride(from: 2, to: 62, by: 20).map {
            [0xad, 0x31, 0x0c] + Array(bytes[$0..<($0 + 20)])
        }
    }

    public static func pcm(_ bytes: [UInt8]) -> [Int16]? {
        guard bytes.count == 64, bytes[0] == 0x1c else { return nil }
        return stride(from: 4, to: 64, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }

    static func command(_ bytes: [UInt8]) -> UInt8? {
        guard bytes.count >= 8,
              bytes[0] == 0x05, bytes[1] == 0xff,
              bytes[2] == 0xf1 || bytes[2] == 0xf0,
              bytes[3] == 0xfe, bytes[4] == 0xc0 else { return nil }
        let end = 7 + Int(bytes[6])
        guard end < bytes.count, bytes[end] == 0xef else { return nil }
        return bytes[5]
    }

    /// AI 键按下上报 9F/33，松开上报 9F/42；其他报告返回 nil。
    static func aiKeyPressed(_ bytes: [UInt8]) -> Bool? {
        guard command(bytes) == 0x9f, bytes[6] == 1 else { return nil }
        switch bytes[7] {
        case 0x33: return true
        case 0x42: return false
        default: return nil
        }
    }

    /// 蓝牙下厂商接口也会收到报告编号 02 的标准键盘报告：修饰键、保留字节、六个键码。
    /// 任何修饰键或键码按下都视为打字并停麦。
    static func isKeyDown(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 9, bytes[0] == 0x02 else { return false }
        return bytes[1] != 0 || bytes[3...8].contains { $0 != 0 }
    }
}

public struct MiSbcFrame: Equatable, Sendable {
    public static let length = 23
    public static let sampleCount = 80
    public static let header: [UInt8] = [0xad, 0x31, 0x0c]
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) throws {
        guard bytes.count == Self.length, Array(bytes.prefix(3)) == Self.header else {
            throw MicFrameError.invalidHeader
        }
        self.bytes = bytes
    }

    public var payload: ArraySlice<UInt8> { bytes[3..<Self.length] }
}

public enum MicFrameError: Error, Equatable {
    case invalidHeader
}

public enum MicTrigger: Equatable, Sendable {
    case aiPressed, aiReleased
    case keyPressed(report: [UInt8])
}

/// 调用方提供单调递增的秒数，并在 needsReconnect 后关闭句柄、重新枚举。
public struct MicSession: Sendable {
    private enum Phase: Sendable { case idle, heartbeat, verify, open, voice, streaming, paused }
    private var phase: Phase = .idle
    private var started = 0.0
    private var due = 0.0
    private var lastHeartbeat = 0.0
    private var lastReply = 0.0
    private var lastAudio: Double?
    private var lastVoice = 0.0
    private var retries = 0
    private var micOn = false
    private var awaitingVoice = false
    public private(set) var needsReconnect = false
    public private(set) var isReady = false
    public private(set) var micEnabled: Bool
    public private(set) var lastTrigger: MicTrigger?
    /// 每记录一个新 lastTrigger 递增，调用方以此可靠消费边沿。
    public private(set) var triggerID = 0
    private let pushToTalk: Bool

    /// pushToTalk 为真时启动即停麦，按住 AI 键才推流；否则麦克风常开。
    public init(pushToTalk: Bool = false) {
        self.pushToTalk = pushToTalk
        micEnabled = !pushToTalk
    }

    public mutating func start(now: Double) -> [Command] {
        self = MicSession(pushToTalk: pushToTalk)
        phase = .heartbeat
        started = now
        lastHeartbeat = now
        lastReply = now
        return [Command(code: 5)]
    }

    public mutating func receive(_ bytes: [UInt8], now: Double) -> [Command] {
        guard phase != .idle, !needsReconnect else { return [] }
        if MicProtocol.pcm(bytes) != nil || MicProtocol.bluetoothFrames(bytes) != nil {
            if phase == .streaming { lastAudio = now; retries = 0; micOn = true; awaitingVoice = false }
            return []
        }
        if let pressed = MicProtocol.aiKeyPressed(bytes) {
            // 常开模式下 AI 键边沿仅对外报告（用于映射键注入），不影响推流。
            if pushToTalk { return setMic(pressed, trigger: pressed ? .aiPressed : .aiReleased, now: now) }
            lastTrigger = pressed ? .aiPressed : .aiReleased
            triggerID += 1
            return []
        }
        // 推流挤占链路时 AI 键松开报告可能丢失，打字即可证明已松开。
        if pushToTalk, micEnabled, MicProtocol.isKeyDown(bytes) {
            return setMic(false, trigger: .keyPressed(report: Array(bytes.prefix(9))), now: now)
        }
        guard let code = MicProtocol.command(bytes) else { return [] }
        if code == 104 {
            lastReply = now
            if phase == .heartbeat {
                phase = .verify
                return [Command(code: 12), Command(code: 15, payload: (0..<32).map { _ in UInt8.random(in: .min ... .max) })]
            }
        } else if code == 227, phase == .verify {
            phase = .open
            due = now + 0.15
            return [Command(code: 17)]
        } else if code == 106, micEnabled {
            // 只在固件自开麦边沿应答，避免每次 106 都发 3 形成回包风暴。
            let spontaneous = !micOn && !awaitingVoice
            micOn = true
            awaitingVoice = false
            if spontaneous { return [Command(code: 3)] }
        } else if code == 107, phase == .streaming, !awaitingVoice {
            // 常开模式下，物理松键可能让固件停麦；立即恢复，重复通知不重复发命令。
            micOn = false
            lastAudio = nil
            lastReply = now
            awaitingVoice = true
            lastVoice = now
            return [Command(code: 3)]
        }
        return []
    }

    public mutating func tick(now: Double) -> [Command] {
        guard phase != .idle, !needsReconnect else { return [] }
        // 推流证明链路仍存活，不能因心跳被音频挤压而误断线。
        let audioActive = lastAudio.map { now - $0 < 2 } ?? false
        let lastAlive = max(lastReply, lastAudio ?? lastReply)
        if (!isReady && now - started >= 4) || (isReady && !audioActive && now - lastAlive >= 4) {
            needsReconnect = true
            isReady = false
            return [Command(code: 4)]
        }
        var result: [Command] = []
        if phase == .open, now >= due {
            result.append(Command(code: 1))
            phase = .voice
            due = now + 0.15
        } else if phase == .voice, now >= due {
            isReady = true
            if micEnabled {
                result.append(Command(code: 3))
                phase = .streaming
                lastVoice = now
                awaitingVoice = true
            } else {
                phase = .paused
            }
        } else if phase == .streaming, !audioActive, now - lastVoice >= 2 {
            if retries >= 2 {
                needsReconnect = true
                isReady = false
                return [Command(code: 4)]
            }
            retries += 1
            lastVoice = now
            awaitingVoice = true
            result.append(Command(code: 3))
        }
        if now - lastHeartbeat >= (audioActive ? 3 : 1) {
            lastHeartbeat = now
            result.append(Command(code: 5))
        }
        return result
    }

    private mutating func setMic(_ enabled: Bool, trigger: MicTrigger, now: Double) -> [Command] {
        if enabled != micEnabled { lastTrigger = trigger; triggerID += 1 }
        micEnabled = enabled
        if micEnabled, phase == .paused {
            phase = .streaming
            retries = 0
            lastVoice = now
            awaitingVoice = true
            return [Command(code: 3)]
        }
        if !micEnabled, phase == .streaming {
            // 停麦后仍靠心跳回包判活，从停麦时刻起算超时。
            phase = .paused
            micOn = false
            awaitingVoice = false
            lastAudio = nil
            lastReply = now
            return [Command(code: 4)]
        }
        return []
    }
}
