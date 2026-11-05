#if os(macOS)
import Foundation
import Darwin

struct MacService {
    private static let label = "local.anykeymic"
    private static var domain: String { "gui/\(getuid())" }
    private static var service: String { "\(domain)/\(label)" }
    private static var plist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    private static func launchctl(_ arguments: [String], checked: Bool = true) throws -> (code: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        // 合并输出并在等待退出前读取，避免任一管道写满导致死锁。
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if checked && process.terminationStatus != 0 {
            throw Failure(description: "launchctl \(arguments.joined(separator: " ")) 失败（\(process.terminationStatus)）：\(output)")
        }
        return (process.terminationStatus, output)
    }

    static func install(executable: URL, log: URL) throws {
        try stop()
        let manager = FileManager.default
        try manager.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let definition: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "run", "--background"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 15,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path
        ]
        try PropertyListSerialization.data(fromPropertyList: definition, format: .xml, options: 0)
            .write(to: plist, options: .atomic)
        _ = try launchctl(["enable", service])
        try start()
    }

    static func uninstall() throws {
        try stop()
        if isInstalled { try FileManager.default.removeItem(at: plist) }
    }

    static func start() throws {
        guard isInstalled else { throw Failure(description: "服务尚未安装，请先执行 install。") }
        if try launchctl(["print", service], checked: false).code != 0 {
            _ = try launchctl(["bootstrap", domain, plist.path])
        }
        _ = try launchctl(["kickstart", service])
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var observedPID: Int32?
        var runningSince = ProcessInfo.processInfo.systemUptime
        var lastOutput = ""
        repeat {
            let result = try launchctl(["print", service], checked: false)
            lastOutput = result.output
            let pid = result.code == 0 ? runningPID(in: result.output) : nil
            let now = ProcessInfo.processInfo.systemUptime
            if pid == nil || pid != observedPID { runningSince = now }
            observedPID = pid
            // 同一 PID 持续存活一秒，排除启动即退出与快速重启循环。
            if pid != nil && now - runningSince >= 1 { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        let state = field("state", in: lastOutput) ?? "未知"
        let exitCode = field("last exit code", in: lastOutput) ?? "未知"
        throw Failure(description: "未能在 5 秒内确认后台进程持续运行。launchd 状态：\(state)，上次退出码：\(exitCode)。请查看运行日志。")
    }

    static func stop() throws {
        let result = try launchctl(["print", service], checked: false)
        guard result.code == 0 else { return }
        let pid = field("pid", in: result.output).flatMap(Int32.init)
        _ = try launchctl(["bootout", service])
        // 标签消失时旧进程仍可能持有设备与锁，同时等待进程退出。
        // 只用信号 0 探测，不向 PID 发送终止信号，避免误杀重用该 PID 的进程。
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            let loaded = try launchctl(["print", service], checked: false).code == 0
            let alive = pid.map(processExists) ?? false
            if !loaded && !alive { return }
            Thread.sleep(forTimeInterval: 0.1)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw Failure(description: "服务 \(label) 未能在 10 秒内退出。")
    }

    static func status() throws -> String {
        let result = try launchctl(["print", service], checked: false)
        let state: String
        if result.code != 0 {
            state = "未加载"
        } else if runningPID(in: result.output) != nil {
            state = "运行中"
        } else if let value = field("state", in: result.output), value != "running" {
            state = "已加载，尚未运行（\(value)）"
        } else {
            state = "已加载，无法确认进程状态"
        }
        return "已安装：\(isInstalled ? "是" : "否")\n已加载：\(result.code == 0 ? "是" : "否")\n运行状态：\(state)"
    }

    private static func processExists(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    private static func runningPID(in output: String) -> Int32? {
        guard field("state", in: output) == "running",
              let pid = field("pid", in: output).flatMap(Int32.init),
              processExists(pid) else { return nil }
        return pid
    }

    private static func field(_ name: String, in output: String) -> String? {
        // launchctl print 是诊断文本，并非稳定的机器接口。字段缺失时不能确认运行成功。
        let prefix = "\(name) = "
        return output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}
#endif
