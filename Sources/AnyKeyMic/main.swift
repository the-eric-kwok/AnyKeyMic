import Foundation
import MicCore
import CNative

#if os(Windows)
if !CommandLine.arguments.dropFirst().contains("--background") { am_console_attach() }
#endif

typealias Settings = MicSettings
struct Failure: Error, CustomStringConvertible { let description: String }
func nativeError() -> Failure { Failure(description: String(cString: am_error())) }
private let logLock = NSLock()
private var logSequence = 0
private var logOutput = FileHandle.standardError
private let logDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
func platformName() -> String {
    #if os(Windows)
    return "Windows"
    #elseif os(macOS)
    return "macOS"
    #else
    return "unknown"
    #endif
}
func log(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }
    logSequence += 1
    let line = "\(logDateFormatter.string(from: Date())) seq=\(logSequence) mono=\(String(format: "%.6f", now())) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
    logOutput.write(Data(line.utf8))
}
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func hex(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
func commandCodes(_ commands: [Command]) -> String {
    commands.map { String(format: "%02X", $0.bytes[5]) }.joined(separator: ",")
}
func send(_ commands: [Command], reportLength: Int = 64) throws {
    for command in commands {
        guard let report = command.encoded(channel: 0xf1, reportLength: reportLength) else {
            throw Failure(description: "HID 命令长度与传输接口不匹配。")
        }
        log("hid_tx code=\(String(format: "0x%02X", command.bytes[5])) len=\(reportLength) payloadLen=\(command.bytes[6])")
        let result = report.withUnsafeBufferPointer { am_hid_write($0.baseAddress, Int32($0.count)) }
        guard result > 0 else { throw nativeError() }
    }
}
func isVirtual(_ name: String) -> Bool {
    let name = name.lowercased()
    return name.contains("cable input") || name.contains("blackhole")
}
func configurationURL() -> URL {
    if let path = ProcessInfo.processInfo.environment["ANYKEYMIC_CONFIG"], !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    #if os(Windows)
    // 固定安装目录使用相邻配置，登录时不依赖安装工具的 MSIX 路径重定向。
    if let executable = try? ServiceManager.currentExecutable() {
        let bin = executable.deletingLastPathComponent()
        let data = bin.deletingLastPathComponent()
        if bin.lastPathComponent.lowercased() == "bin", data.lastPathComponent.lowercased() == "anykeymic" {
            return data.appendingPathComponent("config.json")
        }
    }
    // 从发布目录配置时也跟随已安装实例，避免不同终端的 AppData 重定向产生两份配置。
    var installedPath = [CChar](repeating: 0, count: 131_072)
    if am_service_executable_path(&installedPath, Int32(installedPath.count)) == 1 {
        let installed = URL(fileURLWithPath: String(cString: installedPath))
        let bin = installed.deletingLastPathComponent()
        if installed.lastPathComponent.lowercased() == "anykey-mic.exe",
           bin.lastPathComponent.lowercased() == "bin",
           bin.deletingLastPathComponent().lastPathComponent.lowercased() == "anykeymic" {
            return bin.deletingLastPathComponent().appendingPathComponent("config.json")
        }
    }
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
func readSettings(from url: URL = configurationURL()) throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
}
func printSettings(_ settings: Settings, at url: URL = configurationURL()) {
    print("已保存开麦模式：\(settings.mode.displayName)（\(settings.mode.rawValue)）")
    print("AI 键映射：\(settings.aiKeyMap.map { "\(KeyNames.name($0))（键码 \($0)）" } ?? "未映射")")
    print("配置：\(url.path)")
}
func settingsSaved() {
    print("已保存，正在运行的新版程序会自动应用；旧版程序需更新并重启。")
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
func run(settings initial: Settings, duration: Double?, modeOverride: MicMode?) {
    let deadline = duration.map { now() + $0 }
    var attempt = 0
    var candidate = 0
    var lastProblem = ""
    var settings = initial
    var mapped = settings.aiKeyMap
    let configURL = configurationURL()
    var pendingSettings: Settings?
    var checkSettingsAt = now()
    var lastConfigError = ""
    var keyHeld = false
    log("process_start platform=\(platformName()) configuredMode=\(settings.mode.rawValue) override=\(modeOverride?.rawValue ?? "none") mappedKey=\(mapped.map { "\($0):\(KeyNames.name($0))" } ?? "none") config=\(configURL.path)")
    @discardableResult func injectKey(_ pressed: Bool) -> Bool {
        guard let mapped, pressed != keyHeld else { return true }
        log("key_inject request platform=\(platformName()) key=\(KeyNames.name(mapped)) code=\(mapped) pressed=\(pressed) heldBefore=\(keyHeld)")
        guard am_key_inject(mapped, pressed ? 1 : 0) == 0 else {
            log("key_inject result=error error=\(String(cString: am_error()))")
            return false
        }
        keyHeld = pressed
        log("key_inject result=ok heldAfter=\(keyHeld)")
        return true
    }
    func reportSettings() {
        log("settings_applied mode=\(settings.mode.rawValue) mappedKey=\(mapped.map { "\($0):\(KeyNames.name($0))" } ?? "none")")
        if mapped != nil, am_key_ready() != 0 { log("AI 键映射不可用：\(String(cString: am_error()))") }
    }
    func configurationChanged() -> Bool {
        guard now() >= checkSettingsAt else { return false }
        checkSettingsAt = now() + 0.5
        do {
            let latest = try readSettings(from: configURL)
            lastConfigError = ""
            if latest != settings { pendingSettings = latest; return true }
        } catch {
            let message = String(describing: error)
            if message != lastConfigError {
                log("settings_reload_failed error=\(message)；继续使用已生效配置。")
                lastConfigError = message
            }
        }
        return false
    }
    reportSettings()
    defer { injectKey(false) }
    while am_should_stop() == 0 && (deadline == nil || now() < deadline!) {
        if let updated = pendingSettings {
            guard injectKey(false) else { Thread.sleep(forTimeInterval: 0.2); continue }
            settings = updated
            mapped = updated.aiKeyMap
            pendingSettings = nil
            reportSettings()
        }
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
            let pushToTalk = (modeOverride ?? settings.mode).usesPushToTalk(isBluetooth: isBluetooth)
            log("session_open platform=\(platformName()) hidIndex=\(index) pid=\(String(format: "0x%04X", am_hid_product_id(index))) usage=\(String(format: "0x%04X", am_hid_usage_page(index))) reportLength=\(reportLength) outputID=\(settings.outputID) outputName=\(settings.outputName) mode=\(pushToTalk ? "push_to_talk" : "always_on")")
            guard am_audio_open(output) == 0 else { throw nativeError() }
            guard am_hid_open(index) == 0 else { throw nativeError() }
            defer { try? send([Command(code: 4)], reportLength: reportLength) }
            var swiftSbc = MiSbcLiveDecoder()
            var session = MicSession(pushToTalk: pushToTalk)
            try send(session.start(now: now()), reportLength: reportLength)
            var buffer = [UInt8](repeating: 0, count: 512)
            var samples = 0
            var peak = 0
            var dropped = 0
            var reportAt = now() + 10
            var announced = false
            var handledTrigger = 0
            var rxSequence = 0
            var lastPacketAt: Double?
            var zeroReads = 0
            var keyboardReports = 0
            var commandReports = 0
            var sbcReports = 0
            var pcmReports = 0
            var unknownReports = 0
            var decodedFrames = 0
            var decodeFailures = 0
            var decodeTime = 0.0
            var audioEvents = 0
            var lastKeyboardReport: [UInt8]?
            log("session_ready state=\(session.debugState) output=\(settings.outputName)")
            while am_should_stop() == 0 && (deadline == nil || now() < deadline!) {
                if configurationChanged() { break }
                let audioEvent = am_audio_event()
                if audioEvent != 0 {
                    audioEvents += 1
                    log("audio_event type=\(audioEvent == 1 ? "stopped" : "rerouted")")
                }
                guard am_audio_alive() != 0 else { throw Failure(description: "音频设备断开或路由变化。") }
                let length = buffer.withUnsafeMutableBufferPointer { am_hid_read($0.baseAddress, Int32($0.count)) }
                guard length >= 0 else { throw nativeError() }
                let time = now()
                if length == 0 {
                    zeroReads += 1
                } else {
                    let packet = Array(buffer.prefix(Int(length)))
                    rxSequence += 1
                    let delta = lastPacketAt.map { (time - $0) * 1000 } ?? 0
                    lastPacketAt = time
                    if packet.first == 0x1b {
                        sbcReports += 1
                        if sbcReports <= 3 { log("hid_rx seq=\(rxSequence) kind=sbc len=\(length) dtMs=\(String(format: "%.3f", delta))") }
                    } else if packet.first == 0x1c {
                        pcmReports += 1
                        if pcmReports <= 3 { log("hid_rx seq=\(rxSequence) kind=pcm len=\(length) dtMs=\(String(format: "%.3f", delta))") }
                    } else if packet.first == 0x02, packet.count >= 9 {
                        keyboardReports += 1
                        if lastKeyboardReport != packet {
                            log("hid_rx seq=\(rxSequence) kind=keyboard len=\(length) dtMs=\(String(format: "%.3f", delta)) keyDown=\(MicProtocol.keyboardReportHasKeyDown(packet)) head=\(hex(packet.prefix(9)))")
                            lastKeyboardReport = packet
                        }
                    } else if let code = MicProtocol.commandCode(packet) {
                        commandReports += 1
                        log("hid_rx seq=\(rxSequence) kind=command code=\(String(format: "0x%02X", code)) len=\(length) dtMs=\(String(format: "%.3f", delta)) head=\(hex(packet.prefix(9)))")
                    } else {
                        unknownReports += 1
                        if unknownReports <= 5 || unknownReports % 100 == 0 {
                            log("hid_rx seq=\(rxSequence) kind=unknown len=\(length) dtMs=\(String(format: "%.3f", delta)) head=\(hex(packet.prefix(16)))")
                        }
                    }
                    let previousState = session.debugState
                    let acceptedAudio = session.acceptsAudio
                    let commands = session.receive(packet, now: time)
                    if acceptedAudio && !session.acceptsAudio { swiftSbc.reset() }
                    if session.acceptsAudio, packet.first == 0x1b, let frames = MicProtocol.bluetoothFrames(packet) {
                        let decodeStarted = now()
                        let pcm: [Int16]
                        do {
                            pcm = try swiftSbc.decode(frames)
                        } catch {
                            decodeFailures += 1
                            log("sbc_decode result=error frameCount=\(frames.count) error=\(error)")
                            throw error
                        }
                        decodeTime += now() - decodeStarted
                        decodedFrames += frames.count
                        let accepted = pcm.withUnsafeBufferPointer { am_audio_push($0.baseAddress, Int32($0.count)) }
                        guard accepted >= 0 else { throw nativeError() }
                        samples += pcm.count; dropped += pcm.count - Int(accepted)
                        for value in pcm { peak = max(peak, abs(Int(value))) }
                        if !announced { log("已自动开麦，Swift SBC 解码正常。"); announced = true; attempt = 0; lastProblem = "" }
                    }
                    if let keyState = MicProtocol.aiKeyState(packet) {
                        log("ai_key state=\(keyState ? "down" : "up") seq=\(rxSequence) session=\(session.debugState)")
                    }
                    try send(commands, reportLength: reportLength)
                    if previousState != session.debugState {
                        log("session_state source=receive before={\(previousState)} after={\(session.debugState)} commands=[\(commandCodes(commands))]")
                    }
                    if session.triggerID != handledTrigger {
                        handledTrigger = session.triggerID
                        let downNote = mapped.map { "，同时按下\(KeyNames.name($0))" } ?? ""
                        let upNote = mapped.map { "，同时松开\(KeyNames.name($0))" } ?? ""
                        switch session.lastTrigger {
                        case .aiPressed:
                            injectKey(true)
                            log(pushToTalk ? "AI 键按下：开麦\(downNote)。" : "AI 键按下\(downNote)。")
                        case .aiReleased:
                            injectKey(false)
                            log(pushToTalk ? "AI 键松开：停麦\(upNote)。" : "AI 键松开\(upNote)。")
                        case .keyPressed(let report):
                            injectKey(false)
                            log("按键停麦，报告：" + report.map { String(format: "%02X", $0) }.joined(separator: " ") + "\(upNote)。")
                        case nil: break
                        }
                    }
                    if session.acceptsAudio, let pcm = MicProtocol.pcm(packet) {
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
                let tickCommands = session.tick(now: time)
                try send(tickCommands, reportLength: reportLength)
                if !tickCommands.isEmpty {
                    log("session_tick state=\(session.debugState) commands=[\(commandCodes(tickCommands))]")
                }
                if session.needsReconnect { throw Failure(description: "会话或音频超时，准备重新连接。") }
                if time >= reportAt {
                    log("stats interval=10s hidRx=\(rxSequence) zeroReads=\(zeroReads) keyboard=\(keyboardReports) command=\(commandReports) sbc=\(sbcReports) pcm=\(pcmReports) unknown=\(unknownReports) decodedFrames=\(decodedFrames) decodeFailures=\(decodeFailures) decodeMs=\(String(format: "%.1f", decodeTime * 1000)) samples=\(samples) peak=\(peak) bufferDropped=\(dropped) audioEvents=\(audioEvents) state=\(session.debugState)")
                    samples = 0; peak = 0; dropped = 0; reportAt = time + 10
                    rxSequence = 0; zeroReads = 0; keyboardReports = 0; commandReports = 0; sbcReports = 0; pcmReports = 0; unknownReports = 0; decodedFrames = 0; decodeFailures = 0; decodeTime = 0; audioEvents = 0
                }
            }
        } catch {
            let message = String(describing: error)
            if message != lastProblem { log(message); lastProblem = message }
            // 会话重建期间 AI 键状态未知，先松开映射键避免粘键。
            injectKey(false)
        }
        if am_should_stop() != 0 { break }
        if pendingSettings != nil { continue }
        attempt = min(attempt + 1, 4)
        let retryAt = now() + min(pow(2, Double(attempt)), 15)
        while now() < retryAt && am_should_stop() == 0 && (deadline == nil || now() < deadline!) {
            if configurationChanged() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    log("桥接已停止。")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let action = arguments.first ?? "help"
    if ServiceManager.commands.contains(action) {
        guard arguments.count == 1 else { throw Failure(description: "\(action) 不接受额外参数。") }
        try ServiceManager.perform(action)
    } else if action == "devices" || action == "configure" {
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
                                    aiKeyMap: existing?.aiKeyMap, mode: existing?.mode ?? .auto)
            try saveSettings(settings, to: url)
            print("已绑定：\(name)\n配置：\(url.path)")
            settingsSaved()
        }
    } else if action == "probe" {
        let seconds = arguments.count == 3 && arguments[1] == "--seconds" ? (Double(arguments[2]) ?? 10) : 10
        try probeHID(seconds: seconds)
    } else if action == "mode" {
        let url = configurationURL()
        var settings = try readSettings(from: url)
        guard arguments.count <= 2 else { throw Failure(description: "用 mode 查询，或 mode auto／always-on／push-to-talk 切换。") }
        if arguments.count == 2 {
            guard let mode = MicMode(rawValue: arguments[1]) else { throw Failure(description: "模式必须是 auto、always-on 或 push-to-talk。") }
            settings.mode = mode
            try saveSettings(settings, to: url)
            settingsSaved()
        }
        printSettings(settings, at: url)
    } else if action == "keymap" {
        let url = configurationURL()
        guard arguments.count <= 2, let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            throw Failure(description: "先用 configure <序号> 绑定虚拟声卡，再配置 AI 键映射。")
        }
        if arguments.count == 2, arguments[1] == "status" {
            printSettings(settings, at: url)
        } else if arguments.count == 2, arguments[1] == "test" {
            guard let code = settings.aiKeyMap else { throw Failure(description: "当前未配置映射，先用 keymap 捕获。") }
            print("将在 1 秒后按下「\(KeyNames.name(code))」并保持约 2 秒，请先把光标移到任意输入框。")
            Thread.sleep(forTimeInterval: 1)
            guard am_key_inject(code, 1) == 0 else { throw nativeError() }
            Thread.sleep(forTimeInterval: 2)
            guard am_key_inject(code, 0) == 0 else { throw nativeError() }
            print("已注入一次按下与松开，观察输入法语音输入是否弹出。")
        } else if arguments.count == 2 {
            if arguments[1] == "none" { settings.aiKeyMap = nil }
            else {
                #if os(Windows)
                let validRange: ClosedRange<Int32> = 1...254
                #else
                let validRange: ClosedRange<Int32> = 0...127
                #endif
                guard let code = Int32(arguments[1]), validRange.contains(code) else {
                    throw Failure(description: "用 keymap 捕获、keymap <键码> 设置、keymap status 查询、keymap test 试注入，或 keymap none 清除。")
                }
                settings.aiKeyMap = code
            }
            try saveSettings(settings, to: url)
            printSettings(settings, at: url)
            settingsSaved()
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
                settingsSaved()
                if am_key_ready() != 0 {
                    print("警告：\(String(cString: am_error()))")
                }
            }
        }
    } else if action == "run" {
        var duration: Double?
        var modeOverride: MicMode?
        let background = arguments.contains("--background")
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--seconds":
                guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]), seconds > 0, seconds.isFinite else {
                    throw Failure(description: "--seconds 后需要正数秒数。")
                }
                duration = seconds
                index += 2
            case "--always-on", "--push-to-talk":
                guard modeOverride == nil else { throw Failure(description: "--always-on 与 --push-to-talk 只能选择一个。") }
                modeOverride = arguments[index] == "--always-on" ? .alwaysOn : .pushToTalk
                index += 1
            case "--background":
                index += 1
            default:
                throw Failure(description: "用 run [--seconds <秒>] [--always-on|--push-to-talk] 启动。")
            }
        }
        guard am_process_start() == 0 else {
            throw Failure(description: "已有 AnyKeyMic 正在运行，或无法取得单实例锁：\(nativeError())")
        }
        if background { logOutput = try ServiceManager.openLog() }
        let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configurationURL()))
        run(settings: settings, duration: duration, modeOverride: modeOverride)
    } else {
        print("""
        AnyKeyMic：USB 键盘麦克风桥接
          devices                列出输出设备
          configure <序号>        绑定虚拟声卡
          keymap [status|none|test|键码]    捕获、查询、清除、测试或指定 AI 键映射
          mode [auto|always-on|push-to-talk]  查询或保存开麦模式
          run [--seconds <秒>] [--always-on|--push-to-talk]    临时覆盖模式并运行
          install                安装到固定用户目录、注册登录自启并启动
          uninstall              取消登录自启并停止，保留程序、配置与日志
          start | stop | restart 管理后台进程；stop 保留登录自启
          status                 查看安装状态、运行状态与日志路径
        默认开麦模式：\(MicMode.auto.displayName)。
        配置 keymap 后，按住 AI 键会同时按下映射键（如 fn、右 Ctrl），用于触发输入法的语音输入。运行前退出 AnyKey AI，避免两个程序争用键盘。
        """)
        if !["help", "--help", "-h"].contains(action) { throw Failure(description: "未知命令：\(action)") }
    }
} catch {
    log(String(describing: error))
    exit(1)
}


