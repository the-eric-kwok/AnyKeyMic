import Foundation

public struct Command: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(code: UInt8, payload: [UInt8] = []) {
        precondition(payload.count <= 56)
        let frame = [UInt8(0x05), 0xff, 0xf1, 0xfe, 0xc0, code, UInt8(payload.count)] + payload + [0xef]
        bytes = frame + Array(repeating: 0, count: 64 - frame.count)
    }
}

public enum MicProtocol {
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
}

/// 调用方提供单调递增的秒数，并在 needsReconnect 后关闭句柄、重新枚举。
public struct MicSession: Sendable {
    private enum Phase: Sendable { case idle, heartbeat, verify, open, voice, streaming }
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

    public init() {}

    public mutating func start(now: Double) -> [Command] {
        self = MicSession()
        phase = .heartbeat
        started = now
        lastHeartbeat = now
        lastReply = now
        return [Command(code: 5)]
    }

    public mutating func receive(_ bytes: [UInt8], now: Double) -> [Command] {
        guard phase != .idle, !needsReconnect else { return [] }
        if MicProtocol.pcm(bytes) != nil {
            if phase == .streaming { lastAudio = now; retries = 0; micOn = true; awaitingVoice = false }
            return []
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
        } else if code == 106 {
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
            result.append(Command(code: 3))
            phase = .streaming
            isReady = true
            lastVoice = now
            awaitingVoice = true
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
}
