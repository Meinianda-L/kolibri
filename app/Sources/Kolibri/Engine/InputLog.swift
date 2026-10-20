import Foundation

/// Why fingers were lifted, with timestamps: ~/.kolibri/logs/input.log.
/// When a player reports 断触, this file says which path did it.
enum InputLog {
    private static let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kolibri/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("input.log")
    }()
    private static let queue = DispatchQueue(label: "kolibri.inputlog")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func write(_ line: String) {
        let text = "\(stamp.string(from: Date())) \(line)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(text.utf8))
                try? h.close()
            } else {
                try? Data(text.utf8).write(to: url)
            }
        }
    }
}
