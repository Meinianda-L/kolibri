import Foundation

/// UI language. The source strings are Chinese; English comes from `englishStrings`
/// (Strings+en.swift, generated from Resources/en.json by scripts/i18n.py).
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, zh, en

    public static let defaultsKey = "appLanguage"

    /// The language strings are shown in right now.
    public static var resolved: AppLanguage {
        switch AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system {
        case .zh: return .zh
        case .en: return .en
        case .system: return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
        }
    }
}

/// Localize a UI string. `s` is the Chinese text as written in the source, after
/// interpolation; templates with {} placeholders match interpolated strings.
public func L(_ s: String) -> String {
    guard AppLanguage.resolved == .en else { return s }
    if let e = englishStrings[s] { return e }
    return Translator.shared.template(s) ?? s
}

private final class Translator: @unchecked Sendable {
    static let shared = Translator()
    private let lock = NSLock()
    private var cache: [String: String?] = [:]
    private let templates: [(NSRegularExpression, String)] = englishStrings.compactMap { zh, en in
        guard zh.contains("{}") else { return nil }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: zh)
            .replacingOccurrences(of: "\\{\\}", with: "(.*?)") + "$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        return (re, en)
    }

    func template(_ s: String) -> String? {
        lock.lock()
        if let hit = cache[s] { lock.unlock(); return hit }
        lock.unlock()
        // Not under the lock: filling a placeholder calls L() again.
        var out: String?
        let range = NSRange(s.startIndex..., in: s)
        for (re, en) in templates {
            guard let m = re.firstMatch(in: s, range: range) else { continue }
            var result = en
            for i in 1..<m.numberOfRanges {
                let r = Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
                if let p = result.range(of: "{}") { result.replaceSubrange(p, with: L(r)) }
            }
            out = result
            break
        }
        lock.lock()
        if cache.count > 2000 { cache.removeAll() }
        cache[s] = out
        lock.unlock()
        return out
    }
}
