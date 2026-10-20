import Foundation
import KolibriCore

/// Operation recordings as `.vprec` JSON in ~/.kolibri/recordings.
enum RecordingStore {
    static let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kolibri/recordings", isDirectory: true)

    struct Item: Identifiable, Hashable {
        let url: URL
        let recording: OperationRecording
        var id: URL { url }
    }

    static func list() -> [Item] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "vprec" }
            .compactMap { u in load(u).map { Item(url: u, recording: $0) } }
            .sorted { $0.recording.createdAt > $1.recording.createdAt }
    }

    static func load(_ url: URL) -> OperationRecording? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(OperationRecording.self, from: d)
    }

    @discardableResult
    static func save(_ r: OperationRecording, to url: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let target = url ?? uniqueURL(r.name)
        try enc.encode(r).write(to: target, options: .atomic)
        return target
    }

    static func importFile(_ src: URL) throws -> URL {
        guard var r = load(src) else { throw KolibriCtl.Failure(message: L("不是有效的操作录制文件")) }
        r.name = src.deletingPathExtension().lastPathComponent
        return try save(r)
    }

    static func delete(_ item: Item) { try? FileManager.default.removeItem(at: item.url) }

    private static func uniqueURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "／")
        var u = dir.appendingPathComponent("\(safe).vprec")
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(safe) \(n).vprec")
            n += 1
        }
        return u
    }
}
