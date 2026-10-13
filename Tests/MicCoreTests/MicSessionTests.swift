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
