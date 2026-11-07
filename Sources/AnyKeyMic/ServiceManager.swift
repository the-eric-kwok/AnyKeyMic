import Foundation
import CNative

enum ServiceManager {
    static let commands: Set<String> = ["install", "uninstall", "start", "stop", "restart", "status"]
    private static let files = FileManager.default
    static var directory: URL {
        let config = configurationURL()
        #if os(Windows)
        var path = [CChar](repeating: 0, count: 131_072)
        // MSIX 可只重定向文件，目录句柄仍指向原目录，因此解析已有配置文件。
        if am_resolve_path(config.path, &path, Int32(path.count)) == 0 {
            return URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
        }
        #endif
        return config.deletingLastPathComponent()
    }
    static var executable: URL {
        #if os(Windows)
        return directory.appendingPathComponent("bin/anykey-mic.exe")
        #else
        return directory.appendingPathComponent("anykey-mic")
        #endif
    }
    static var logURL: URL {
        #if os(Windows)
        return directory.appendingPathComponent("run.log")
        #else
        return files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AnyKeyMic/run.log")
        #endif
    }

    static func openLog() throws -> FileHandle {
        try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: logURL.path) {
            guard files.createFile(atPath: logURL.path, contents: nil) else {
                throw Failure(description: "无法创建日志：\(logURL.path)")
            }
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }

    private static func requireConfiguration() throws {
        do {
            _ = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configurationURL()))
        } catch {
            throw Failure(description: "请先用 configure <序号> 绑定虚拟声卡；配置缺失或无效：\(configurationURL().path)")
        }
    }

    static func currentExecutable() throws -> URL {
        #if os(Windows)
        var path = [CChar](repeating: 0, count: 131_072)
        guard am_executable_path(&path, Int32(path.count)) == 0 else { throw nativeError() }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        #else
        guard let url = Bundle.main.executableURL else {
            throw Failure(description: "无法确定当前程序路径。")
        }
        return url.resolvingSymlinksInPath()
        #endif
    }

    // 先完整准备新文件，停止旧实例后再替换。失败时恢复被替换的文件。
    private static func deploy(_ source: URL) throws {
        let destination = executable.deletingLastPathComponent()
        #if os(Windows)
        let sameLocation = source.path.caseInsensitiveCompare(executable.resolvingSymlinksInPath().path) == .orderedSame
        #else
        let sameLocation = source == executable.resolvingSymlinksInPath()
        #endif
        if sameLocation { try stop(); return }
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".install-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        var cleanStaging = true
        defer { if cleanStaging { try? files.removeItem(at: staging) } }
        var sources = [source]
        #if os(Windows)
        let siblings = try files.contentsOfDirectory(at: source.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        guard siblings.contains(where: { $0.lastPathComponent.lowercased() == "swiftcore.dll" }) else {
            throw Failure(description: "安装需要完整发布目录，请先运行 scripts/package-windows.ps1，再执行 dist/anykey-mic.exe install。")
        }
        sources += siblings.filter { $0.pathExtension.lowercased() == "dll" || ["LICENSE", "THIRD_PARTY.md"].contains($0.lastPathComponent) }
        #endif
        for item in sources {
            let name = item == source ? executable.lastPathComponent : item.lastPathComponent
            try files.copyItem(at: item, to: staging.appendingPathComponent(name))
        }
        try stop()
        let backup = staging.appendingPathComponent("backup")
        try files.createDirectory(at: backup, withIntermediateDirectories: false)
        var replaced: [URL] = []
        var saved: [URL] = []
        do {
            for item in sources {
                let name = item == source ? executable.lastPathComponent : item.lastPathComponent
                let target = destination.appendingPathComponent(name)
                if files.fileExists(atPath: target.path) {
                    try files.moveItem(at: target, to: backup.appendingPathComponent(name))
                    saved.append(target)
                }
                try files.moveItem(at: staging.appendingPathComponent(name), to: target)
                replaced.append(target)
            }
        } catch {
            var recoveryError: Error?
            for target in replaced.reversed() {
                do { try files.removeItem(at: target) } catch { recoveryError = error }
            }
            for target in saved.reversed() {
                do { try files.moveItem(at: backup.appendingPathComponent(target.lastPathComponent), to: target) }
                catch { recoveryError = error }
            }
            if let recoveryError {
                cleanStaging = false
                throw Failure(description: "安装失败：\(error)。恢复旧文件失败：\(recoveryError)。备份保留在：\(backup.path)")
            }
            throw error
        }
    }

    private static func stop() throws {
        #if os(Windows)
        guard am_service_stop() == 0 else { throw nativeError() }
        #else
        try MacService.stop()
        #endif
    }

    private static func start() throws {
        try requireConfiguration()
        guard files.fileExists(atPath: executable.path) else { throw Failure(description: "请先执行 install。") }
        #if os(Windows)
        let installed = am_service_registered(executable.path)
        guard installed >= 0 else { throw nativeError() }
        guard installed == 1 else { throw Failure(description: "登录启动项缺失或来自旧版，请先执行 install。") }
        try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard am_service_start(executable.path) == 0 else { throw nativeError() }
        #else
        try MacService.start()
        #endif
    }

    static func perform(_ action: String) throws {
        switch action {
        case "install":
            try requireConfiguration()
            try deploy(currentExecutable())
            try files.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(Windows)
            guard am_service_register(executable.path) == 0 else { throw nativeError() }
            try start()
            #else
            try MacService.install(executable: executable, log: logURL)
            #endif
            print("已安装并启动当前用户登录自启。")
        case "uninstall":
            #if os(Windows)
            try stop()
            guard am_service_unregister() == 0 else { throw nativeError() }
            #else
            try MacService.uninstall()
            #endif
            print("已取消登录自启并停止运行，程序、配置与日志已保留。")
        case "start":
            try start()
            print("后台进程已启动；设备连接状态请查看日志。")
        case "stop":
            try stop()
            print("已停止运行，登录自启设置保持不变。")
        case "restart":
            try requireConfiguration()
            try stop()
            try start()
            print("后台进程已重启。")
        case "status":
            #if os(Windows)
            let installed = am_service_registered(executable.path)
            let running = am_service_running()
            guard installed >= 0, running >= 0 else { throw nativeError() }
            print("已安装：\(installed == 1 ? "是" : "否")\n正在运行：\(running == 1 ? "是" : "否")")
            #else
            print(try MacService.status())
            #endif
            if let settings = try? readSettings() { printSettings(settings) }
        default: preconditionFailure("未知管理命令")
        }
        print("程序：\(executable.path)\n日志：\(logURL.path)")
    }
}
