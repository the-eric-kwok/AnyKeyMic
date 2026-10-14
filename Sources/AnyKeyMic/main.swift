import Foundation
import MicCore
import CNative

struct Settings: Codable {
    let outputID: String
    let outputName: String
}
struct Failure: Error, CustomStringConvertible { let description: String }
func nativeError() -> Failure { Failure(description: String(cString: am_error())) }
func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func send(_ commands: [Command], reportLength: Int = 64) throws {
    for command in commands {
        guard let report = command.encoded(channel: 0xf1, reportLength: reportLength) else {
            throw Failure(description: "HID 命令长度与传输接口不匹配。")
        }
        let result = report.withUnsafeBufferPointer { am_hid_write($0.baseAddress, Int32($0.count)) }
        guard result > 0 else { throw nativeError() }
    }
}
func isVirtual(_ name: String) -> Bool {
    let name = name.lowercased()
    return name.contains("cable input") || name.contains("blackhole")
}
func configurationURL() -> URL {
    #if os(Windows)
    let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    #else
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
    #endif
    return URL(fileURLWithPath: base).appendingPathComponent("AnyKeyMic/config.json")
}
func printDevices() {
    for i in 0..<max(0, am_output_count()) {
        let name = String(cString: am_output_name(i))
        print("\(i)\t\(name)\(isVirtual(name) ? "  ← 虚拟声卡" : "")")
    }
    let hidCount = am_hid_count()
    print("键盘厂商接口数：\(hidCount)")
    for i in 0..<hidCount {
        print("  HID[\(i)] PID：\(String(format: "%04X", am_hid_product_id(Int32(i))))，Usage：\(String(format: "%04X", am_hid_usage_page(Int32(i))))")
    }
}
func probeHID(seconds: Double) throws {
    guard am_init() == 0 else { throw nativeError() }
    defer { am_shutdown() }
    let count = am_hid_count()
    guard count > 0 else { throw Failure(description: "没有找到受支持 HID 接口。") }
    let index = (0..<count).first { am_hid_product_id($0) == 0x8243 } ?? 0
    guard am_hid_open(index) == 0 else { throw nativeError() }
    defer { am_hid_close() }
    try send([Command(code: 5)], reportLength: am_hid_product_id(index) == 0x8243 ? 62 : 64)
    let end = now() + seconds
    var buffer = [UInt8](repeating: 0, count: 512)
    var packets = 0
    while now() < end {
        let length = buffer.withUnsafeMutableBufferPointer { am_hid_read($0.baseAddress, Int32($0.count)) }
        guard length >= 0 else { throw nativeError() }
        if length > 0 {
            packets += 1
            let head = buffer.prefix(min(Int(length), 8)).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("HID[\(index)] len=\(length) head=\(head)")
        }
    }
    print("探针结束：\(packets) 个报文。")
}
func run(settings: Settings, duration: Double?) {
    let deadline = duration.map { now() + $0 }
    var attempt = 0
    var candidate = 0
    var lastProblem = ""
    while am_should_stop() == 0 && (deadline == nil || now() < deadline!) {
        do {
            guard am_init() == 0 else { throw nativeError() }
            defer { am_shutdown() }
            let output = (0..<max(0, am_output_count())).first {
                String(cString: am_output_id($0)) == settings.outputID
            }
            guard let output, isVirtual(String(cString: am_output_name(output))) else {
                throw Failure(description: "已绑定的虚拟声卡不可用，等待恢复。")
            }
            let count = am_hid_count()
            guard count > 0 else { throw Failure(description: "等待受支持的 HID 键盘（USB 8102 或蓝牙 8243）。") }
            let bluetooth = (0..<count).first { am_hid_product_id($0) == 0x8243 }
            let index: Int32
            if let bluetooth { index = bluetooth }
            else { index = Int32(candidate % Int(count)); candidate += 1 }
            let reportLength = am_hid_product_id(index) == 0x8243 ? 62 : 64
            candidate += 1
            guard am_audio_open(output) == 0 else { throw nativeError() }
            guard am_hid_open(index) == 0 else { throw nativeError() }
            defer { try? send([Command(code: 4)], reportLength: reportLength) }
            var swiftSbc = MiSbcLiveDecoder()
            var session = MicSession()
            try send(session.start(now: now()), reportLength: reportLength)
            var buffer = [UInt8](repeating: 0, count: 512)
            var samples = 0
            var peak = 0
            var dropped = 0
            var reportAt = now() + 10
            var announced = false
            log("建立 HID 会话，输出：\(settings.outputName)，麦克风常开")
            while am_should_stop() == 0 && (deadline == nil || now() < deadline!) {
                guard am_audio_alive() != 0 else { throw Failure(description: "音频设备断开或路由变化。") }
                let length = buffer.withUnsafeMutableBufferPointer { am_hid_read($0.baseAddress, Int32($0.count)) }
                guard length >= 0 else { throw nativeError() }
                let time = now()
                if length > 0 {
                    let packet = Array(buffer.prefix(Int(length)))
                    if packet.first == 0x1b, let frames = MicProtocol.bluetoothFrames(packet) {
                        let pcm = try swiftSbc.decode(frames)
                        let accepted = pcm.withUnsafeBufferPointer { am_audio_push($0.baseAddress, Int32($0.count)) }
                        guard accepted >= 0 else { throw nativeError() }
                        samples += pcm.count; dropped += pcm.count - Int(accepted)
                        for value in pcm { peak = max(peak, abs(Int(value))) }
                        if !announced { log("已自动开麦，Swift SBC 解码正常。"); announced = true; attempt = 0; lastProblem = "" }
                    }
                    try send(session.receive(packet, now: time), reportLength: reportLength)
                    if session.isReady, let pcm = MicProtocol.pcm(packet) {
                        let accepted = pcm.withUnsafeBufferPointer { am_audio_push($0.baseAddress, Int32($0.count)) }
                        guard accepted >= 0 else { throw nativeError() }
                        samples += pcm.count
                        dropped += pcm.count - Int(accepted)
                        for value in pcm { peak = max(peak, abs(Int(value))) }
                        if !announced {
                            log("已自动开麦，开始接收 PCM。")
                            announced = true; attempt = 0; lastProblem = ""
                        }
                    }
                }
                try send(session.tick(now: time), reportLength: reportLength)
                if session.needsReconnect { throw Failure(description: "会话或音频超时，准备重新连接。") }
                if time >= reportAt {
                    log("最近约十秒：\(samples) 样本，峰值 \(peak)，缓冲丢弃 \(dropped) 样本。")
                    samples = 0; peak = 0; dropped = 0; reportAt = time + 10
                }
            }
        } catch {
            let message = String(describing: error)
            if message != lastProblem { log(message); lastProblem = message }
        }
        if am_should_stop() != 0 { break }
        attempt = min(attempt + 1, 4)
        let retryAt = now() + min(pow(2, Double(attempt)), 15)
        while now() < retryAt && am_should_stop() == 0 && (deadline == nil || now() < deadline!) {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    log("桥接已停止。")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let action = arguments.first ?? "help"
    if action == "devices" || action == "configure" {
        guard am_init() == 0 else { throw nativeError() }
        defer { am_shutdown() }
        if action == "devices" { printDevices() }
        else {
            guard arguments.count == 2, let index = Int32(arguments[1]),
                  index >= 0, index < am_output_count() else {
                throw Failure(description: "用 configure <序号> 绑定 devices 列出的虚拟声卡。")
            }
            let name = String(cString: am_output_name(index))
            guard isVirtual(name) else { throw Failure(description: "仅允许 CABLE Input 或 BlackHole，防止回音。") }
            let settings = Settings(outputID: String(cString: am_output_id(index)), outputName: name)
            let url = configurationURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: url, options: .atomic)
            print("已绑定：\(name)\n配置：\(url.path)")
        }
    } else if action == "probe" {
        let seconds = arguments.count == 3 && arguments[1] == "--seconds" ? (Double(arguments[2]) ?? 10) : 10
        try probeHID(seconds: seconds)
    } else if action == "run" {
        let duration: Double?
        if arguments.count == 1 { duration = nil }
        else if arguments.count == 3, arguments[1] == "--seconds", let seconds = Double(arguments[2]), seconds > 0, seconds.isFinite {
            duration = seconds
        } else { throw Failure(description: "用 run 或 run --seconds 30 启动。") }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configurationURL()))
        guard am_process_start() == 0 else { throw Failure(description: "已有 AnyKeyMic 正在运行，或无法取得单实例锁。") }
        run(settings: settings, duration: duration)
    } else {
        print("AnyKeyMic：USB 键盘麦克风桥接\n  devices                列出输出设备\n  configure <序号>        绑定虚拟声卡\n  run [--seconds <秒>]    自动开麦并持续重连\n运行前退出 AnyKey AI，避免两个程序争用键盘。")
    }
} catch {
    log(String(describing: error))
    exit(1)
}


