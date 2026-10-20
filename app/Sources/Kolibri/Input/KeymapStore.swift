import Foundation
import KolibriCore

/// Keyboard/mouse schemes and gamepad schemes are managed separately;
/// 键鼠 / 手柄 tabs; one of each is active per game and both feed the engine.
enum SchemeKind: String, CaseIterable, Identifiable {
    case keyboard, gamepad
    var id: String { rawValue }
    var title: String { L(self == .keyboard ? "键鼠" : "手柄") }
}

/// Schemes live as plain JSON so they are easy to share and diff:
///
///     ~/.kolibri/keymaps/<package>/<keyboard|gamepad>/<scheme name>.json
///     ~/.kolibri/keymaps/<package>/selected.json   {"keyboard": "...", "gamepad": "..."}
enum KeymapStore {
    static let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kolibri/keymaps", isDirectory: true)

    static func folder(_ package: String?) -> URL {
        root.appendingPathComponent(package ?? "_global", isDirectory: true)
    }

    static func folder(_ package: String?, _ kind: SchemeKind) -> URL {
        folder(package).appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    private static func file(_ package: String?, _ kind: SchemeKind, _ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")
        return folder(package, kind).appendingPathComponent("\(safe).json")
    }

    // MARK: Listing & selection

    /// Scheme names, oldest first (creation order is the order users built them in).
    static func list(_ package: String?, _ kind: SchemeKind) -> [String] {
        migrateLegacy(package)
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder(package, kind), includingPropertiesForKeys: [.creationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a < b
            }
            .compactMap { load(url: $0)?.name }
    }

    static func load(_ package: String?, _ kind: SchemeKind, _ name: String) -> Keymap? {
        load(url: file(package, kind, name))
    }

    private static func load(url: URL) -> Keymap? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Keymap.self, from: data)
    }

    static func selectedName(_ package: String?, _ kind: SchemeKind) -> String? {
        guard let data = try? Data(contentsOf: folder(package).appendingPathComponent("selected.json")),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return d[kind.rawValue]
    }

    static func select(_ package: String?, _ kind: SchemeKind, _ name: String?) {
        let url = folder(package).appendingPathComponent("selected.json")
        var d = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
        d[kind.rawValue] = name
        try? FileManager.default.createDirectory(at: folder(package), withIntermediateDirectories: true)
        try? JSONEncoder().encode(d).write(to: url, options: .atomic)
    }

    /// 「不使用方案」: stored as an empty selection.
    static func isDisabled(_ package: String?, _ kind: SchemeKind) -> Bool {
        selectedName(package, kind) == ""
    }

    /// The active scheme for a game, falling back to its first scheme, else an empty one.
    static func active(_ package: String?, _ kind: SchemeKind) -> Keymap {
        if isDisabled(package, kind) { return Keymap(name: "", package: package, controls: []) }
        let names = list(package, kind)
        if let n = selectedName(package, kind), let k = load(package, kind, n) { return k }
        if let n = names.first, let k = load(package, kind, n) { return k }
        return empty(package: package, kind: kind)
    }

    static func empty(package: String?, kind: SchemeKind) -> Keymap {
        Keymap(name: kind == .keyboard ? "默认键鼠方案" : "默认手柄方案", package: package, controls: [])
    }

    // MARK: Editing

    static func save(_ keymap: Keymap, kind: SchemeKind) throws {
        try FileManager.default.createDirectory(at: folder(keymap.package, kind), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(keymap).write(to: file(keymap.package, kind, keymap.name), options: .atomic)
    }

    static func delete(_ package: String?, _ kind: SchemeKind, _ name: String) {
        try? FileManager.default.removeItem(at: file(package, kind, name))
        if selectedName(package, kind) == name { select(package, kind, nil) }
    }

    static func rename(_ package: String?, _ kind: SchemeKind, _ old: String, to new: String) throws {
        guard var k = load(package, kind, old) else { return }
        k.name = uniqueName(package, kind, new)
        try save(k, kind: kind)
        try? FileManager.default.removeItem(at: file(package, kind, old))
        if selectedName(package, kind) == old { select(package, kind, k.name) }
    }

    static func uniqueName(_ package: String?, _ kind: SchemeKind, _ base: String) -> String {
        let taken = Set(list(package, kind))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Import a scheme file into a game. Gamepad schemes are recognised by their bindings.
    static func importFile(_ src: URL, package: String?) throws -> (Keymap, SchemeKind) {
        var k = try JSONDecoder().decode(Keymap.self, from: Data(contentsOf: src))
        let kind: SchemeKind = k.controls.contains { c in c.triggers.contains(where: \.isPad) } &&
            !k.controls.contains { c in c.triggers.contains { !$0.isPad } } ? .gamepad : .keyboard
        k.package = package
        k.name = uniqueName(package, kind, k.name)
        try save(k, kind: kind)
        return (k, kind)
    }

    static func export(_ keymap: Keymap, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(keymap).write(to: url, options: .atomic)
    }

    /// Earlier builds stored one `<package>.json` per game.
    private static func migrateLegacy(_ package: String?) {
        let old = root.appendingPathComponent("\(package ?? "_global").json")
        guard FileManager.default.fileExists(atPath: old.path), let k = load(url: old) else { return }
        try? save(k, kind: .keyboard)
        try? FileManager.default.removeItem(at: old)
    }

    // MARK: Templates

    /// Optional starter layout the user can apply from the editor and then adjust.
    static func actionTemplate(package: String?) -> Keymap {
        Keymap(name: "动作游戏模板", package: package, controls: [
            .joystick(up: .key(13), down: .key(1), left: .key(0), right: .key(2),
                      center: NPoint(0.14, 0.72), radius: 0.06, stick: "left"),
            .aim(center: NPoint(0.62, 0.42), radius: 0.16, sensitivity: 1.0, stick: "right"),
            .button(binding: .mouse(0), at: NPoint(0.86, 0.62), mode: .hold),
            .button(binding: .mouse(1), at: NPoint(0.93, 0.45), mode: .toggle),
            .button(binding: .key(49), at: NPoint(0.92, 0.80), mode: .click(holdMs: 40)),
            .button(binding: .key(15), at: NPoint(0.80, 0.82), mode: .click(holdMs: 40)),
            .skill(binding: .key(12), at: NPoint(0.74, 0.70), radius: 0.05, options: SkillOptions()),
            .skill(binding: .key(14), at: NPoint(0.80, 0.58), radius: 0.05, options: SkillOptions()),
        ], aimToggle: .key(50))
    }

    /// MOBA starter: skills aim with the walk direction, wheel zooms the map.
    static func mobaTemplate(package: String?) -> Keymap {
        Keymap(name: "MOBA 模板", package: package, controls: [
            .joystick(up: .key(13), down: .key(1), left: .key(0), right: .key(2),
                      center: NPoint(0.13, 0.75), radius: 0.07, stick: "left"),
            .button(binding: .key(49), at: NPoint(0.88, 0.80), mode: .hold),
            .skill(binding: .key(12), at: NPoint(0.70, 0.84), radius: 0.06, options: SkillOptions(followJoystick: false)),
            .skill(binding: .key(14), at: NPoint(0.74, 0.66), radius: 0.06, options: SkillOptions(followJoystick: false)),
            .skill(binding: .key(15), at: NPoint(0.83, 0.56), radius: 0.06, options: SkillOptions(followJoystick: false)),
            .button(binding: .key(3), at: NPoint(0.60, 0.88), mode: .click(holdMs: 40)),
            .button(binding: .key(5), at: NPoint(0.53, 0.88), mode: .click(holdMs: 40)),
        ])
    }

    /// Gamepad starter: left stick walks, right stick aims, face buttons tap.
    static func gamepadTemplate(package: String?) -> Keymap {
        let nop = KolibriCore.Binding.pad("-")
        return Keymap(name: "手柄模板", package: package, controls: [
            .joystick(up: nop, down: nop, left: nop, right: nop, center: NPoint(0.14, 0.72), radius: 0.06, stick: "left"),
            .aim(center: NPoint(0.62, 0.42), radius: 0.16, sensitivity: 1.0, stick: "right"),
            .button(binding: .pad("Button A"), at: NPoint(0.92, 0.80), mode: .hold),
            .button(binding: .pad("Button B"), at: NPoint(0.96, 0.66), mode: .hold),
            .button(binding: .pad("Button X"), at: NPoint(0.84, 0.86), mode: .hold),
            .button(binding: .pad("Button Y"), at: NPoint(0.88, 0.60), mode: .hold),
            .button(binding: .pad("Right Trigger"), at: NPoint(0.86, 0.45), mode: .hold),
        ])
    }

    /// Both active schemes as one engine keymap (settings come from the keyboard scheme).
    static func combined(keyboard kb: Keymap, gamepad pad: Keymap) -> Keymap {
        var k = kb
        k.controls += pad.controls
        return k
    }
}
