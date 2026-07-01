//
//  ADBManager.swift
//  Argus
//
//  Locates the `adb` binary and sets up the reverse tunnels that let the
//  tablet reach the Mac's listening sockets over USB.
//

import Foundation

final class ADBManager {
    private(set) var adbPath: String?

    /// Common Homebrew / SDK locations to probe when adb isn't on PATH.
    private let candidatePaths = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
    ]

    /// Resolve adb. Returns the path or nil if not found.
    @discardableResult
    func locate() -> String? {
        if let viaPath = which("adb") { adbPath = viaPath; return viaPath }
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            adbPath = p
            return p
        }
        return nil
    }

    /// Set up all three reverse tunnels. Returns true if every command
    /// succeeded.
    @discardableResult
    func setupReverseTunnels(silent: Bool = false) -> Bool {
        guard let adb = adbPath ?? locate() else { return false }
        let ports = [ArgusPorts.video, ArgusPorts.input, ArgusPorts.audio]
        var ok = true
        for port in ports {
            let arg = "tcp:\(port)"
            let result = run(adb, ["reverse", arg, arg])
            if result.status != 0 {
                if !silent { NSLog("[Argus] adb reverse \(arg) failed: \(result.output)") }
                ok = false
            } else {
                if !silent { NSLog("[Argus] adb reverse \(arg) -> \(arg) OK") }
            }
        }
        return ok
    }

    func removeReverseTunnels() {
        guard let adb = adbPath else { return }
        _ = run(adb, ["reverse", "--remove-all"])
    }

    func devicesConnected() -> Bool {
        guard let adb = adbPath ?? locate() else { return false }
        let r = run(adb, ["devices"])
        // Lines after the header that end in "\tdevice".
        return r.output
            .split(separator: "\n")
            .dropFirst()
            .contains { $0.contains("\tdevice") }
    }

    // MARK: - Process helpers

    private func which(_ tool: String) -> String? {
        let r = run("/usr/bin/which", [tool])
        let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (r.status == 0 && !path.isEmpty) ? path : nil
    }

    private func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "launch failed: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
