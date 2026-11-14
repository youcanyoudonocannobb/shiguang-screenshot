import AppKit

enum RelaunchFailure: LocalizedError {
    case invalidBundle
    case terminationTimeout

    var errorDescription: String? {
        switch self {
        case .invalidBundle: return "找不到当前应用的可执行文件，请从原来的应用位置重新打开。"
        case .terminationTimeout: return "旧进程尚未退出，已停止重启。请完全退出汪拍后重新打开。"
        }
    }
}

enum AppRelauncher {
    static let helperFlag = "--shiguang-relaunch-after-exit"

    static func arguments(parentPID: Int32, bundleURL: URL) -> [String] {
        [helperFlag, String(parentPID), bundleURL.path]
    }

    static func target(from arguments: [String]) -> (pid: Int32, url: URL)? {
        guard arguments.count == 4, arguments[1] == helperFlag,
              let pid = Int32(arguments[2]), pid > 0, arguments[3].hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        guard url.pathExtension == "app" else { return nil }
        return (pid, url)
    }

    static func start(bundleURL: URL, parentPID: Int32) throws {
        guard bundleURL.pathExtension == "app", let executable = Bundle(url: bundleURL)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RelaunchFailure.invalidBundle
        }
        // Start an independent helper before terminating this process. No shell parses the path.
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = arguments(parentPID: parentPID, bundleURL: bundleURL)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    @MainActor
    static func runHelperIfNeeded() -> Bool {
        guard let target = target(from: ProcessInfo.processInfo.arguments) else { return false }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                for attempt in 0..<200 {
                    if NSRunningApplication(processIdentifier: target.pid)?.isTerminated != false { break }
                    if attempt == 199 { throw RelaunchFailure.terminationTimeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.allowsRunningApplicationSubstitution = false
                configuration.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: target.url, configuration: configuration)
            } catch {
                app.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "重启汪拍失败"
                alert.informativeText = "\(error.localizedDescription)\n应用位置：\(target.url.path)"
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
            app.terminate(nil)
        }
        app.run()
        return true
    }
}
