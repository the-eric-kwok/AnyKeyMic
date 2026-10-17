import XCTest
@testable import MicCore

final class MicSessionTests: XCTestCase {
    private func streamingSession() -> MicSession {
        var session = MicSession()
        _ = session.start(now: 0)
        _ = session.receive(reply(104), now: 0.1)
        _ = session.receive(reply(227), now: 0.2)
        _ = session.tick(now: 0.4)
        _ = session.tick(now: 0.6)
        return session
    }
    private func reply(_ code: UInt8) -> [UInt8] { Command(code: code).bytes }
    private func codes(_ commands: [Command]) -> [UInt8] { commands.map { $0.bytes[5] } }

    func testBluetoothFramesRequireCompleteReportAndAddSBCHeader() {
        var report = Array(repeating: UInt8(0), count: 62)
        report[0] = 0x1b
        for i in 2..<62 { report[i] = UInt8(i) }
        let frames = MicProtocol.bluetoothFrames(report)
        XCTAssertEqual(frames?.count, 3)
        XCTAssertEqual(frames?.map(\.count), [23, 23, 23])
        XCTAssertEqual(frames?[0].prefix(3), [0xad, 0x31, 0x0c])
        XCTAssertEqual(frames?[0].dropFirst(3).first, 2)
        XCTAssertNil(MicProtocol.bluetoothFrames(Array(report.dropLast())))
        report[0] = 0x1c
        XCTAssertNil(MicProtocol.bluetoothFrames(report))
    }

    func testMiSbcFrameValidatesFixedProfileEnvelope() throws {
        let bytes = MiSbcFrame.header + Array(repeating: UInt8(0x55), count: 20)
        let frame = try MiSbcFrame(bytes)
        XCTAssertEqual(frame.bytes.count, 23)
        XCTAssertEqual(frame.payload.count, 20)
        XCTAssertEqual(MiSbcFrame.sampleCount, MiSbcProfile.samplesPerFrame)
        XCTAssertEqual(MiSbcProfile.sampleRate, 16_000)
        XCTAssertEqual(MiSbcProfile.channels, 1)
        XCTAssertEqual(MiSbcProfile.bitpool, 12)
    }

    func testMiSbcFrameRejectsMalformedEnvelope() {
        XCTAssertThrowsError(try MiSbcFrame(Array(repeating: 0, count: 23))) { error in
            XCTAssertEqual(error as? MicFrameError, .invalidHeader)
        }
        XCTAssertThrowsError(try MiSbcFrame(Array(repeating: 0, count: 22)))
    }

    func testMiSbcReferenceDecoderConsumesFixedProfileBitstream() throws {
        let bytes = MiSbcFrame.header + [0, 0x11, 0x11, 0x11, 0x11] + Array(repeating: UInt8(0), count: 15)
        let decoded = try MiSbcReferenceDecoder().decodeSubbands(try MiSbcFrame(bytes), validateCRC: false)
        XCTAssertEqual(decoded.scaleFactors.count, 8)
        XCTAssertEqual(decoded.samples.count, 10)
        XCTAssertTrue(decoded.samples.allSatisfy { $0.count == 8 })
        XCTAssertEqual(decoded.samples.flatMap { $0 }.count, 80)
    }

    func testMiSbcReferenceDecoderValidatesCapturedFramesWhenAvailable() throws {
        let directory = ".sbc-golden"
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".bin") }
            .sorted()
        guard !files.isEmpty else { return }

        let decoder = MiSbcReferenceDecoder()
        for name in files {
            let packet = Array(try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name)))
            XCTAssertEqual(packet.count, 69, name)
            for index in 0..<3 {
                let frame = try MiSbcFrame(Array(packet[index * 23..<(index + 1) * 23]))
                let subbands = try decoder.decodeSubbands(frame, validateCRC: false)
                XCTAssertEqual(subbands.samples.count, MiSbcProfile.blocks, name)
                XCTAssertEqual(subbands.samples.flatMap { $0 }.count, MiSbcProfile.samplesPerFrame, name)
            }
        }
        XCTAssertGreaterThanOrEqual(files.count, 1)
    }

    func testMiSbcReferenceDecoderRejectsCorruptedCRC() throws {
        let directory = ".sbc-golden"
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".bin") }
            .sorted()
        guard let name = files.first else { return }
        var bytes = Array(try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name)).prefix(23))
        bytes[4] ^= 0x80
        XCTAssertThrowsError(try MiSbcReferenceDecoder().decodeSubbands(try MiSbcFrame(bytes), validateCRC: true)) { error in
            XCTAssertEqual(error as? SBCDecoderError, .invalidCRC)
        }
    }

    func testMiSbcLiveDecoderProducesThreeFramePCM() throws {
        let bytes = MiSbcFrame.header + [0, 0x11, 0x11, 0x11, 0x11] + Array(repeating: UInt8(0), count: 15)
        var decoder = MiSbcLiveDecoder()
        let pcm = try decoder.decode([bytes, bytes, bytes])
        XCTAssertEqual(pcm.count, 3 * MiSbcProfile.samplesPerFrame)
    }
    func testMiSbcSwiftOutputCanBeComparedWithGoldenPCM() throws {
        let directory = ".sbc-golden"
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasPrefix("frame-") && $0.hasSuffix(".bin") }
            .sorted()
        guard !names.isEmpty else { return }
        var decoder = MiSbcLiveDecoder()
        var reference: [Double] = []
        var actual: [Double] = []
        for name in names.prefix(30) {
            let base = URL(fileURLWithPath: directory)
            let packet = Array(try Data(contentsOf: base.appendingPathComponent(name)))
            let frames = stride(from: 0, to: 69, by: 23).map { Array(packet[$0..<$0 + 23]) }
            actual.append(contentsOf: try decoder.decode(frames).map(Double.init))
            let pcmName = name.replacingOccurrences(of: "frame-", with: "pcm-")
            let bytes = Array(try Data(contentsOf: base.appendingPathComponent(pcmName)))
            for index in stride(from: 0, to: bytes.count, by: 2) {
                reference.append(Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)))
            }
        }
        let dot = zip(actual, reference).reduce(0) { $0 + $1.0 * $1.1 }
        let actualNorm = sqrt(actual.reduce(0) { $0 + $1 * $1 })
        let referenceNorm = sqrt(reference.reduce(0) { $0 + $1 * $1 })
        let correlation = dot / max(actualNorm * referenceNorm, 1)
        let rmsRatio = actualNorm / max(referenceNorm, 1)
        XCTAssertGreaterThan(correlation, 0.999)
        XCTAssertGreaterThan(rmsRatio, 0.99)
        XCTAssertLessThan(rmsRatio, 1.01)
        print("Swift golden correlation: \(correlation), RMS ratio: \(rmsRatio)")
    }

    func testMiSbcSynthesisProducesStableZeroFrame() throws {
        let subbands = MiSbcSubbandFrame(
            scaleFactors: Array(repeating: 0, count: MiSbcProfile.subbands),
            samples: Array(repeating: Array(repeating: 0, count: MiSbcProfile.subbands), count: MiSbcProfile.blocks)
        )
        var filter = MiSbcSynthesisFilter()
        XCTAssertEqual(filter.synthesize(subbands), Array(repeating: 0, count: MiSbcProfile.samplesPerFrame))
        XCTAssertEqual(filter.synthesize(subbands).count, MiSbcProfile.samplesPerFrame)
        filter.reset()
        XCTAssertEqual(filter.synthesize(subbands).max(), 0)
    }

    func testBluetoothAudioKeepsSessionAlive() {
        var session = streamingSession()
        var report = Array(repeating: UInt8(0), count: 62)
        report[0] = 0x1b
        _ = session.receive(report, now: 5)
        _ = session.tick(now: 5)
        XCTAssertFalse(session.needsReconnect)
    }

    func testEncodedCommandHonorsBluetoothChannelsAndReportLengths() {
        let command = Command(code: 3, payload: [1, 2])
        XCTAssertEqual(command.encoded(channel: 0xf1, reportLength: 62)?.count, 62)
        XCTAssertEqual(command.encoded(channel: 0xf1, reportLength: 64)?.count, 64)
        XCTAssertEqual(command.encoded(channel: 0xf0, reportLength: 64)?.count, 64)
        XCTAssertNil(command.encoded(channel: 0xf0, reportLength: 62))
        XCTAssertNil(command.encoded(channel: 0xf1, reportLength: 61))
        XCTAssertNil(Command(code: 3, payload: Array(repeating: 0, count: 56)).encoded(channel: 0xf1, reportLength: 62))
    }

    func testHandshakeAndVoiceTiming() {
        var session = MicSession()
        XCTAssertEqual(codes(session.start(now: 0)), [5])
        let verification = session.receive(reply(104), now: 0.1)
        XCTAssertEqual(codes(verification), [12, 15])
        XCTAssertEqual(verification[1].bytes.count, 64)
        XCTAssertEqual(verification[1].bytes[6], 32)
        XCTAssertEqual(codes(session.receive(reply(227), now: 0.2)), [17])
        XCTAssertTrue(session.tick(now: 0.34).isEmpty)
        XCTAssertEqual(codes(session.tick(now: 0.36)), [1])
        XCTAssertFalse(session.isReady)
        XCTAssertTrue(session.tick(now: 0.50).isEmpty)
        XCTAssertEqual(codes(session.tick(now: 0.52)), [3])
        XCTAssertTrue(session.isReady)
    }

    func testMalformedFramesCannotAdvanceHandshake() {
        var session = MicSession()
        _ = session.start(now: 0)
        for frame in [[], [5], [5, 255, 241, 254, 192, 104, 255, 239], [5, 255, 241, 254, 192, 104, 0, 0]] as [[UInt8]] {
            XCTAssertTrue(session.receive(frame, now: 0.1).isEmpty)
        }
        XCTAssertEqual(codes(session.receive(reply(227), now: 0.2)), [])
        _ = session.tick(now: 4)
        XCTAssertTrue(session.needsReconnect)
    }

    func testPCMUsesLittleEndianAndSkipsHeader() {
        var frame = Array(repeating: UInt8(0), count: 64)
        frame[0] = 0x1c
        frame[4] = 0xff; frame[5] = 0x7f
        frame[6] = 0; frame[7] = 0x80
        let pcm = MicProtocol.pcm(frame)
        XCTAssertEqual(pcm?.count, 30)
        XCTAssertEqual(pcm?.prefix(2), [32767, -32768])
        XCTAssertNil(MicProtocol.pcm(Array(frame.dropLast())))
        frame[0] = 0x1b
        XCTAssertNil(MicProtocol.pcm(frame))
    }

    func testRestartResetsFailureAndSilentStreamRetries() {
        var session = MicSession()
        _ = session.start(now: 0)
        _ = session.tick(now: 4)
        XCTAssertTrue(session.needsReconnect)
        XCTAssertEqual(codes(session.start(now: 10)), [5])
        XCTAssertFalse(session.needsReconnect)
        _ = session.receive(reply(104), now: 10.1)
        _ = session.receive(reply(227), now: 10.2)
        _ = session.tick(now: 10.4)
        _ = session.tick(now: 10.6)
        for time in [12.7, 14.8] {
            _ = session.receive(reply(104), now: time)
            XCTAssertTrue(codes(session.tick(now: time)).contains(3))
        }
        _ = session.receive(reply(104), now: 16.9)
        XCTAssertEqual(codes(session.tick(now: 16.9)), [4])
        XCTAssertTrue(session.needsReconnect)
    }

    func testActiveAudioPreventsHeartbeatFalseDisconnect() {
        var session = MicSession()
        _ = session.start(now: 0)
        _ = session.receive(reply(104), now: 0.1)
        _ = session.receive(reply(227), now: 0.2)
        _ = session.tick(now: 0.4)
        _ = session.tick(now: 0.6)
        var pcm = Array(repeating: UInt8(0), count: 64)
        pcm[0] = 0x1c
        _ = session.receive(pcm, now: 5)
        _ = session.tick(now: 5)
        XCTAssertFalse(session.needsReconnect)
    }

    func testFirmwareStopRestartsAlwaysOnWithoutDuplicateCommands() {
        var session = streamingSession()
        XCTAssertTrue(session.receive(reply(106), now: 0.7).isEmpty)
        XCTAssertEqual(codes(session.receive(reply(107), now: 1)), [3])
        XCTAssertTrue(session.receive(reply(107), now: 1.01).isEmpty)
        XCTAssertTrue(session.receive(reply(106), now: 1.1).isEmpty)
        XCTAssertTrue(session.receive(reply(106), now: 1.11).isEmpty)
        XCTAssertEqual(codes(session.receive(reply(107), now: 2)), [3])
    }

    func testSpontaneousFirmwareOpenIsAcknowledgedOnce() {
        var session = MicSession()
        _ = session.start(now: 0)
        XCTAssertEqual(codes(session.receive(reply(106), now: 0.1)), [3])
        XCTAssertTrue(session.receive(reply(106), now: 0.2).isEmpty)
        XCTAssertFalse(session.isReady)
    }

    private func aiKey(_ value: UInt8) -> [UInt8] { Command(code: 0x9f, payload: [value]).bytes }

    func testHoldingAIKeyStreamsOnlyWhilePressed() {
        var session = MicSession(pushToTalk: true)
        _ = session.start(now: 0)
        _ = session.receive(reply(104), now: 0.1)
        _ = session.receive(reply(227), now: 0.2)
        _ = session.tick(now: 0.4)
        XCTAssertFalse(codes(session.tick(now: 0.6)).contains(3))
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.receive(aiKey(0x42), now: 0.7).isEmpty)
        XCTAssertEqual(codes(session.receive(aiKey(0x33), now: 0.8)), [3])
        XCTAssertTrue(session.receive(aiKey(0x33), now: 0.9).isEmpty)
        XCTAssertTrue(session.micEnabled)
        XCTAssertEqual(codes(session.receive(aiKey(0x42), now: 1)), [4])
        XCTAssertFalse(session.micEnabled)
        XCTAssertTrue(session.receive(reply(107), now: 1.1).isEmpty)
        _ = session.receive(reply(104), now: 3.5)
        XCTAssertFalse(codes(session.tick(now: 3.5)).contains(3))
        XCTAssertFalse(session.needsReconnect)
    }

    func testTypingStopsPushToTalkWhenReleaseIsLost() {
        var session = MicSession(pushToTalk: true)
        _ = session.start(now: 0)
        _ = session.receive(reply(104), now: 0.1)
        _ = session.receive(reply(227), now: 0.2)
        _ = session.tick(now: 0.4)
        _ = session.tick(now: 0.6)
        _ = session.receive(aiKey(0x33), now: 1)
        var key = Array(repeating: UInt8(0), count: 62)
        key[0] = 0x02
        XCTAssertTrue(session.receive(key, now: 2).isEmpty)
        key[1] = 0x10
        XCTAssertEqual(codes(session.receive(key, now: 2.05)), [4])
        XCTAssertFalse(session.micEnabled)
        XCTAssertEqual(session.lastTrigger, .keyPressed(report: Array(key.prefix(9))))
        XCTAssertTrue(session.receive(key, now: 2.06).isEmpty)
        _ = session.receive(aiKey(0x33), now: 2.07)
        key[1] = 0
        key[3] = 0x04
        XCTAssertEqual(codes(session.receive(key, now: 2.1)), [4])
        XCTAssertFalse(session.micEnabled)
        XCTAssertEqual(session.lastTrigger, .keyPressed(report: Array(key.prefix(9))))
        XCTAssertTrue(session.receive(key, now: 2.2).isEmpty)
    }

    func testAIKeyReleaseIsReportedSeparately() {
        var session = MicSession(pushToTalk: true)
        _ = session.start(now: 0)
        _ = session.receive(aiKey(0x33), now: 0.1)
        _ = session.receive(aiKey(0x42), now: 0.2)
        XCTAssertEqual(session.lastTrigger, .aiReleased)
    }

    func testAlwaysOnReportsAIKeyEdgesButKeepsMicOn() {
        var session = streamingSession()
        var key = Array(repeating: UInt8(0), count: 62)
        key[0] = 0x02; key[3] = 0x04
        XCTAssertTrue(session.receive(aiKey(0x33), now: 1).isEmpty)
        XCTAssertEqual(session.lastTrigger, .aiPressed)
        XCTAssertEqual(session.triggerID, 1)
        XCTAssertTrue(session.receive(aiKey(0x42), now: 1.05).isEmpty)
        XCTAssertEqual(session.lastTrigger, .aiReleased)
        XCTAssertEqual(session.triggerID, 2)
        XCTAssertTrue(session.receive(key, now: 1.1).isEmpty)
        XCTAssertEqual(session.triggerID, 2)
        XCTAssertTrue(session.micEnabled)
    }

    func testTriggerIDAdvancesOncePerEdgeInPushToTalk() {
        var session = MicSession(pushToTalk: true)
        _ = session.start(now: 0)
        XCTAssertEqual(session.triggerID, 0)
        _ = session.receive(aiKey(0x33), now: 0.1)
        XCTAssertEqual(session.triggerID, 1)
        _ = session.receive(aiKey(0x33), now: 0.2)
        XCTAssertEqual(session.triggerID, 1)
        _ = session.receive(aiKey(0x42), now: 0.3)
        XCTAssertEqual(session.triggerID, 2)
        XCTAssertEqual(session.lastTrigger, .aiReleased)
        _ = session.receive(aiKey(0x33), now: 0.4)
        var key = Array(repeating: UInt8(0), count: 62)
        key[0] = 0x02; key[3] = 0x04
        _ = session.receive(key, now: 0.5)
        XCTAssertEqual(session.triggerID, 4)
        XCTAssertEqual(session.lastTrigger, .keyPressed(report: Array(key.prefix(9))))
    }

    func testKeyNamesCoverCommonCodes() {
        #if os(Windows)
        XCTAssertEqual(KeyNames.escapeCode, 0x1b)
        XCTAssertEqual(KeyNames.name(0xa3), "右 Ctrl")
        XCTAssertEqual(KeyNames.name(0xa5), "右 Alt")
        XCTAssertEqual(KeyNames.name(0x70), "F1")
        XCTAssertEqual(KeyNames.name(0x7b), "F12")
        #else
        XCTAssertEqual(KeyNames.escapeCode, 0x35)
        XCTAssertEqual(KeyNames.name(0x3f), "fn 键")
        XCTAssertEqual(KeyNames.name(0x3e), "右 Ctrl")
        XCTAssertEqual(KeyNames.name(0x3d), "右 Option")
        XCTAssertEqual(KeyNames.name(0x7a), "F1")
        XCTAssertEqual(KeyNames.name(0x6f), "F12")
        XCTAssertEqual(KeyNames.name(0x1234), "键码 4660")
        #endif
    }

    func testPressDuringHandshakeOpensMicWhenReady() {
        var session = MicSession(pushToTalk: true)
        _ = session.start(now: 0)
        XCTAssertTrue(session.receive(aiKey(0x33), now: 0.05).isEmpty)
        _ = session.receive(reply(104), now: 0.1)
        _ = session.receive(reply(227), now: 0.2)
        _ = session.tick(now: 0.4)
        XCTAssertEqual(codes(session.tick(now: 0.6)), [3])
    }

    func testAudioEndingAllowsHeartbeatRecoveryBeforeDisconnect() {
        var session = streamingSession()
        var pcm = Array(repeating: UInt8(0), count: 64)
        pcm[0] = 0x1c
        _ = session.receive(pcm, now: 10)
        _ = session.tick(now: 12.1)
        XCTAssertFalse(session.needsReconnect)
        _ = session.receive(reply(104), now: 12.2)
        _ = session.tick(now: 14)
        XCTAssertFalse(session.needsReconnect)
    }
}






