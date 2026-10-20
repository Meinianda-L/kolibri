import Foundation

/// One instance as reported by `kolibrictl list --json`.
struct InstanceInfo: Codable, Identifiable, Hashable {
    var name: String
    var slot: Int
    var resolution: [Int]
    var dpi: Int
    var cores: Int
    var ram_mb: Int
    var refresh_hz: Int
    var profile: String
    var provisioned: Bool
    var running: Bool
    /// Stopped from the UI and still saving its snapshot in the background.
    var stopping: Bool?
    var serial: String
    var grpc_port: Int
    var console_port: Int
    /// Engine launcher pid while running.
    var pid: Int?
    /// Google Play services installed (every device by default; `--no-gms` leaves them out).
    var gms: Bool?
    /// su available to apps. Instances created before the switch existed still ship su.
    var root: Bool?
    /// Phone presented to apps when profile == "custom" (brand, model, device, soc_model...).
    var custom_profile: [String: String]?
    /// GPU name override; nil or empty follows the phone model.
    var gpu_renderer: String?
    var device_name: String?
    var phone_number: String?
    var hasGMS: Bool { gms ?? true }
    var hasRoot: Bool { root ?? true }

    var id: String { name }
    var width: Int { resolution.first ?? 1600 }
    var height: Int { resolution.last ?? 900 }
}

/// Thin bridge to engine/kolibrictl. The engine stays a separate process tree so a
/// guest crash can never take the frontend down (and vice versa).
enum KolibriCtl {
    static let scriptURL: URL = {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["KOLIBRI_ENGINE"] {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("engine/kolibrictl"), fm.fileExists(atPath: res.path) {
            return res
        }
        // Dev builds: walk up from the executable to find the repo's engine/kolibrictl.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("engine/kolibrictl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("emulator/engine/kolibrictl")
    }()

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func run(_ args: [String], input: Data? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [scriptURL.path] + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: o.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    cont.resume(throwing: Failure(message: e.isEmpty ? o : e))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Runs a long command and hands over each stdout line as it arrives (setup progress).
    static func stream(_ args: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [scriptURL.path] + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            final class Buffer: @unchecked Sendable { var data = Data() }
            let buf = Buffer()
            out.fileHandleForReading.readabilityHandler = { h in
                buf.data.append(h.availableData)
                while let nl = buf.data.firstIndex(of: 0x0A) {
                    let line = String(decoding: buf.data[..<nl], as: UTF8.self)
                    buf.data.removeSubrange(...nl)
                    onLine(line)
                }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: Failure(message: e.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    static func list() async throws -> [InstanceInfo] {
        let json = try await run(["list", "--json"])
        return try JSONDecoder().decode([InstanceInfo].self, from: Data(json.utf8))
    }

    static func adb(_ name: String, _ args: [String]) async throws -> String {
        try await run(["adb", name] + args)
    }

    /// Foreground Android package, used to auto-select a keymap.
    static func foregroundPackage(_ name: String) async -> String? {
        guard let out = try? await adb(name, ["shell", "dumpsys", "activity", "activities"]) else { return nil }
        for line in out.split(separator: "\n") where line.contains("topResumedActivity") || line.contains("mResumedActivity") {
            // ... ActivityRecord{1234 u0 com.pkg/.Main t12}
            if let r = line.range(of: #"u\d+ ([\w.]+)/"#, options: .regularExpression) {
                let token = line[r].split(separator: " ").last ?? ""
                return String(token.dropLast())
            }
        }
        return nil
    }
}
