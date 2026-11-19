import Foundation

struct DeviceIdentity: Equatable {
    var udid: String?
    var productType: String?
    var deviceName: String?
}

/// Reads the exact device model over USB using libimobiledevice's command-line tools
/// (`brew install libimobiledevice`). Everything here is blocking — call off the main thread.
enum DeviceIdentifier {
    static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func toolPath(_ name: String, customDir: String) -> String? {
        var dirs = searchDirs
        if !customDir.isEmpty { dirs.insert(customDir, at: 0) }
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func isAvailable(customDir: String) -> Bool {
        toolPath("ideviceinfo", customDir: customDir) != nil && toolPath("idevice_id", customDir: customDir) != nil
    }

    static func identify(captureUniqueID: String, captureName: String, customDir: String) -> DeviceIdentity? {
        guard let idTool = toolPath("idevice_id", customDir: customDir),
              let infoTool = toolPath("ideviceinfo", customDir: customDir),
              let list = run(idTool, ["-l"]) else { return nil }

        var seen = Set<String>()
        let udids = list.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let candidates: [DeviceIdentity] = udids.map { udid in
            DeviceIdentity(udid: udid,
                           productType: run(infoTool, ["-u", udid, "-k", "ProductType"]),
                           deviceName: run(infoTool, ["-u", udid, "-k", "DeviceName"]))
        }.filter { $0.productType != nil }

        func norm(_ s: String?) -> String { (s ?? "").replacingOccurrences(of: "-", with: "").lowercased() }
        if let m = candidates.first(where: { norm($0.udid) == norm(captureUniqueID) }) { return m }
        if let m = candidates.first(where: { $0.deviceName == captureName }) { return m }
        if candidates.count == 1 { return candidates[0] }
        return nil
    }

    /// Runs a tool and returns trimmed stdout, or nil on failure / empty output / timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
