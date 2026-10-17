import Foundation
import MicCore
import CNative

struct Settings: Codable {
    let outputID: String
    let outputName: String
    /// AI 键映射的平台键码（macOS 虚拟键码／Windows VK 码），nil 表示不映射。
    var aiKeyMap: Int32?

    init(outputID: String, outputName: String, aiKeyMap: Int32? = nil) {
        self.outputID = outputID
        self.outputName = outputName
        self.aiKeyMap = aiKeyMap
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputID = try values.decode(String.self, forKey: .outputID)
        outputName = try values.decode(String.self, forKey: .outputName)
        aiKeyMap = try values.decodeIfPresent(Int32.self, forKey: .aiKeyMap)
    }
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
func saveSettings(_ settings: Settings, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(settings).write(to: url, options: .atomic)
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
    let mapped = settings.aiKeyMap
    var keyHeld = false
    var keyBroken = false
    func injectKey(_ pressed: Bool) {
        guard let mapped, !keyBroken, pressed != keyHeld else { return }
        guard am_key_inject(mapped, pressed ? 1 : 0) == 0 else {
            keyBroken = true
            keyHeld = false
            log("映射键注入失败：\(String(cString: am_error()))")
            return
        }
        keyHeld = pressed
    }
    if let mapped {
        if am_key_ready() != 0 { log("AI 键映射不可用：\(String(cString: am_error()))") }
        log("AI 键映射已启用：\(KeyNames.name(mapped))（键码 \(mapped)）。")
    }
    defer { injectKey(false) }
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
            let isBluetooth = am_hid_product_id(index) == 0x8243
            let reportLength = isBluetooth ? 62 : 64
            candidate += 1
            guard am_audio_open(output) == 0 else { throw nativeError() }
            guard am_hid_open(index) == 0 else { throw nativeError() }
            defer { try? send([Command(code: 4)], reportLength: reportLength) }
            var swiftSbc = MiSbcLiveDecoder()
            var session = MicSession(pushToTalk: isBluetooth)
            try send(session.start(now: now()), reportLength: reportLength)
            var buffer = [UInt8](repeating: 0, count: 512)
            var samples = 0
            var peak = 0
            var dropped = 0
            var reportAt = now() + 10
            var announced = false
            var handledTrigger = 0
            log("建立 HID 会话，输出：\(settings.outputName)，" + (isBluetooth ? "按住 AI 键说话" : "麦克风常开"))
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
                    if session.triggerID != handledTrigger {
                        handledTrigger = session.triggerID
                        let downNote = mapped.map { "，同时按下\(KeyNames.name($0))" } ?? ""
                        let upNote = mapped.map { "，同时松开\(KeyNames.name($0))" } ?? ""
                        switch session.lastTrigger {
                        case .aiPressed:
                            injectKey(true)
                            log(isBluetooth ? "AI 键按下：开麦\(downNote)。" : "AI 键按下\(downNote)。")
                        case .aiReleased:
                            injectKey(false)
                            log(isBluetooth ? "AI 键松开：停麦\(upNote)。" : "AI 键松开\(upNote)。")
                        case .keyPressed(let report):
                            injectKey(false)
                            log("按键停麦，报告：" + report.map { String(format: "%02X", $0) }.joined(separator: " ") + "\(upNote)。")
                        case nil: break
                        }
                    }
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
                    if samples > 0 { log("最近约十秒：\(samples) 样本，峰值 \(peak)，缓冲丢弃 \(dropped) 样本。") }
                    samples = 0; peak = 0; dropped = 0; reportAt = time + 10
                }
            }
        } catch {
            let message = String(describing: error)
            if message != lastProblem { log(message); lastProblem = message }
            // 会话重建期间 AI 键状态未知，先松开映射键避免粘键。
            injectKey(false)
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
            let url = configurationURL()
            let existing = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            let settings = Settings(outputID: String(cString: am_output_id(index)), outputName: name,
                                    aiKeyMap: existing?.aiKeyMap)
            try saveSettings(settings, to: url)
            print("已绑定：\(name)\n配置：\(url.path)")
        }
    } else if action == "probe" {
        let seconds = arguments.count == 3 && arguments[1] == "--seconds" ? (Double(arguments[2]) ?? 10) : 10
        try probeHID(seconds: seconds)
    } else if action == "keymap" {
        let url = configurationURL()
        guard arguments.count <= 2, let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            throw Failure(description: "先用 configure <序号> 绑定虚拟声卡，再配置 AI 键映射。")
        }
        if arguments.count == 2, arguments[1] == "test" {
            guard let code = settings.aiKeyMap else { throw Failure(description: "当前未配置映射，先用 keymap 捕获。") }
            print("将在 1 秒后按下「\(KeyNames.name(code))」并保持约 2 秒，请先把光标移到任意输入框。")
            Thread.sleep(forTimeInterval: 1)
            guard am_key_inject(code, 1) == 0 else { throw nativeError() }
            Thread.sleep(forTimeInterval: 2)
            guard am_key_inject(code, 0) == 0 else { throw nativeError() }
            print("已注入一次按下与松开，观察输入法语音输入是否弹出。")
        } else if arguments.count == 2 {
            guard arguments[1] == "none" else { throw Failure(description: "用 keymap 交互捕获、keymap test 试注入，或 keymap none 清除映射。") }
            settings.aiKeyMap = nil
            try saveSettings(settings, to: url)
            print("已清除 AI 键映射。")
        } else {
            let current = settings.aiKeyMap.map { "\(KeyNames.name($0))（键码 \($0)）" } ?? "未映射"
            print("按住 AI 键开麦的同时按下映射键，用于一并触发输入法的语音输入。\n当前映射：\(current)")
            print("请按下要映射的按键（Esc 取消）…", terminator: "")
            var code: Int32 = 0
            guard am_key_capture(&code, 30_000) == 0 else { throw nativeError() }
            if code == KeyNames.escapeCode {
                print("\n已取消，映射未修改。")
            } else {
                settings.aiKeyMap = code
                try saveSettings(settings, to: url)
                print("\n已捕获并保存：\(KeyNames.name(code))（键码 \(code)）\n配置：\(url.path)")
                if am_key_ready() != 0 {
                    print("警告：\(String(cString: am_error()))")
                }
            }
        }
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
        print("""
        AnyKeyMic：USB 键盘麦克风桥接
          devices                列出输出设备
          configure <序号>        绑定虚拟声卡
          keymap [none|test]     交互捕获 AI 键映射的目标按键；none 清除；test 试注入一次
          run [--seconds <秒>]    桥接并持续重连，蓝牙下按住 AI 键说话
        配置 keymap 后，按住 AI 键会同时按下映射键（如 fn、右 Ctrl），用于触发输入法的语音输入。运行前退出 AnyKey AI，避免两个程序争用键盘。
        """)
    }
} catch {
    log(String(describing: error))
    exit(1)
}


