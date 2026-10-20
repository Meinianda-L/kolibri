import SwiftUI
import KolibriCore

/// The control palette shown in the keymap sidebar
/// (点击按键、连击按键、方向按键 …). Each entry knows how to create a control at a point.
enum ControlKind: String, CaseIterable, Identifiable {
    case click, burstTap, dpad, crosshair, eye, spell, fire, spellCancel, curve,
         rightWalk, observe, zoom, wheel, gravity, macro, leftStick, rightStick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click: return L("点击按键")
        case .burstTap: return L("连击按键")
        case .dpad: return L("方向按键")
        case .crosshair: return L("准心键")
        case .eye: return L("视角移动")
        case .spell: return L("技能施法")
        case .fire: return L("开火/攻击")
        case .spellCancel: return L("取消施法")
        case .curve: return L("滑动键位")
        case .rightWalk: return L("右键行走")
        case .observe: return L("观察键")
        case .zoom: return L("缩放键")
        case .wheel: return L("滚动键")
        case .gravity: return L("重力感应")
        case .macro: return L("宏")
        case .leftStick: return L("左摇杆")
        case .rightStick: return L("右摇杆")
        }
    }

    var settingsTitle: String {
        switch self {
        case .click: return L("点击按键设置")
        case .burstTap: return L("连击按键设置")
        case .dpad: return L("方向键设置")
        case .crosshair: return L("准心键设置")
        case .eye: return L("视角移动设置")
        case .spell: return L("技能施法设置")
        case .fire: return L("开火/攻击键设置")
        case .spellCancel: return L("取消施法键设置")
        case .curve: return L("滑动键位设置")
        case .rightWalk: return L("右键行走设置")
        case .observe: return L("观察键设置")
        case .zoom: return L("缩放键设置")
        case .wheel: return L("滚动键设置")
        case .gravity: return L("重力感应键设置")
        case .macro: return L("宏设置")
        case .leftStick, .rightStick: return title
        }
    }

    var symbol: String {
        switch self {
        case .click: return "hand.tap"
        case .burstTap: return "hand.tap.fill"
        case .dpad: return "dpad"
        case .crosshair: return "scope"
        case .eye: return "eye"
        case .spell: return "sparkles"
        case .fire: return "flame"
        case .spellCancel: return "xmark.circle"
        case .curve: return "scribble"
        case .rightWalk: return "figure.walk"
        case .observe: return "binoculars"
        case .zoom: return "plus.magnifyingglass"
        case .wheel: return "arrow.up.and.down"
        case .gravity: return "gyroscope"
        case .macro: return "list.bullet.rectangle"
        case .leftStick: return "l.joystick"
        case .rightStick: return "r.joystick"
        }
    }

    /// The right-click add menu. 取消施法 is not listed: it is turned
    /// on from a skill's or fire key's settings; 宏 only comes from
    /// imported schemes.
    static func palette(_ kind: SchemeKind) -> [ControlKind] {
        kind == .keyboard
            ? [.click, .burstTap, .curve, .dpad, .crosshair, .eye, .fire, .rightWalk, .spell,
               .gravity, .wheel, .zoom, .observe]
            : [.click, .burstTap, .curve, .leftStick, .rightStick, .spell]
    }

    /// Only one per scheme.
    var single: Bool {
        switch self {
        case .dpad, .crosshair, .fire, .rightWalk, .gravity, .wheel, .leftStick, .rightStick: return true
        default: return false
        }
    }

    /// The tip on the size handle beside a focused key.
    var sizeTip: String? {
        switch self {
        case .spell, .fire: return L("调整施法范围")
        case .dpad, .crosshair, .eye, .observe, .rightWalk, .leftStick, .rightStick: return L("调整大小")
        default: return nil
        }
    }

    /// A new control of this kind placed at `p`.
    func make(at p: NPoint, pad: Bool) -> Control {
        let k: (UInt16) -> KolibriCore.Binding = { pad ? .pad("Button A") : .key($0) }
        let none = KolibriCore.Binding.pad("-")
        switch self {
        case .click: return .button(binding: k(49), at: p, mode: .hold)
        case .burstTap: return .button(binding: k(3), at: p, mode: .turbo(hz: 10))
        case .dpad:
            return .joystick(up: .key(13), down: .key(1), left: .key(0), right: .key(2), center: p, radius: 0.06, stick: "left")
        case .leftStick: return .joystick(up: none, down: none, left: none, right: none, center: p, radius: 0.06, stick: "left")
        case .crosshair: return .aim(center: p, radius: 0.15, sensitivity: 1, stick: pad ? "right" : nil)
        case .rightStick: return .aim(center: p, radius: 0.15, sensitivity: 1, stick: "right")
        case .eye: return .lookKeys(up: .key(126), down: .key(125), left: .key(123), right: .key(124), center: p, radius: 0.15, speed: 0.6)
        case .spell: return .skill(binding: k(12), at: p, radius: 0.05, options: SkillOptions())
        case .fire: return .fire(binding: .mouse(0), at: p, radius: 0.08, dragAim: false)
        case .spellCancel: return .spellCancel(binding: k(48), at: p)
        case .curve: return .swipe(binding: k(14), path: [p, NPoint(min(p.x + 0.15, 1), p.y)], durationMs: 200)
        case .rightWalk: return .rightWalk(binding: .mouse(1), center: p, radius: 0.06)
        case .observe: return .observe(binding: k(58), at: p, radius: 0.15, sensitivity: 1)
        case .zoom: return .zoomKeys(zoomIn: .key(24), zoomOut: .key(27), center: p)
        case .wheel: return .swipe(binding: k(31), path: [NPoint(p.x, min(p.y + 0.1, 1)), NPoint(p.x, max(p.y - 0.1, 0))], durationMs: 300)
        case .gravity: return .gravity(up: .key(34), down: .key(40), left: .key(38), right: .key(37))
        case .macro: return .macro(binding: k(3), press: [.tap(p, holdMs: 40)], release: [])
        }
    }

    /// Best palette entry for an existing control (for titles and icons).
    static func of(_ c: Control) -> ControlKind {
        switch c {
        case let .button(_, _, mode):
            switch mode { case .turbo, .burst: return .burstTap; default: return .click }
        case let .joystick(u, _, _, _, _, _, _): return u == .pad("-") ? .leftStick : .dpad
        case let .aim(_, _, _, stick): return stick == "right" ? .rightStick : .crosshair
        case .lookKeys: return .eye
        case .skill: return .spell
        case let .swipe(_, path, _):
            if path.count == 2, abs(path[0].x - path[1].x) < 0.001 { return .wheel }
            return .curve
        case .macro: return .macro
        case .fire: return .fire
        case .spellCancel: return .spellCancel
        case .rightWalk: return .rightWalk
        case .observe: return .observe
        case .zoomKeys: return .zoom
        case .gravity: return .gravity
        }
    }
}

/// How a control is drawn: anchor, short label, ring radius (width units), and
/// for 4-key controls the per-direction labels.
enum ControlGeometry {
    struct Shape {
        var anchor: NPoint
        var label: String
        var radius: Double
        var directions: [String]? = nil
    }

    static func typeName(_ c: Control) -> String { ControlKind.of(c).title }

    private static func k(_ b: KolibriCore.Binding) -> String { b == .pad("-") ? "" : KeyNames.name(b) }

    /// With the editor's extras: 备注 replaces the key text, 重力感应 uses its saved spot.
    static func describe(_ c: Control, extra: ControlExtra) -> Shape {
        var s = describe(c)
        if !extra.note.isEmpty, s.directions == nil { s.label = extra.note }
        if case .gravity = c, let p = extra.position { s.anchor = p }
        return s
    }

    static func describe(_ c: Control) -> Shape {
        switch c {
        case let .button(b, at, mode):
            switch mode {
            case .hold: return Shape(anchor: at, label: k(b), radius: 0)
            case let .turbo(hz): return Shape(anchor: at, label: L("\(k(b)) 连\(Int(hz))"), radius: 0)
            case let .burst(n, _): return Shape(anchor: at, label: "\(k(b)) ×\(n)", radius: 0)
            default: return Shape(anchor: at, label: "\(k(b)) \(mode.title)", radius: 0)
            }
        case let .joystick(u, d, l, r, center, radius, stick):
            let dirs = [u, d, l, r].map(k)
            if dirs.allSatisfy(\.isEmpty) { return Shape(anchor: center, label: stick == "left" ? L("左摇杆") : L("摇杆"), radius: radius) }
            return Shape(anchor: center, label: "", radius: radius, directions: dirs)
        case let .aim(center, radius, _, stick): return Shape(anchor: center, label: stick == "right" ? L("右摇杆") : L("准心"), radius: radius)
        case let .lookKeys(u, d, l, r, center, radius, _):
            return Shape(anchor: center, label: L("视角"), radius: radius, directions: [u, d, l, r].map(k))
        case let .skill(b, at, radius, _): return Shape(anchor: at, label: k(b), radius: radius)
        case let .swipe(b, _, _): return Shape(anchor: c.anchor, label: k(b), radius: 0)
        case let .macro(b, _, _): return Shape(anchor: c.anchor, label: L("\(k(b)) 宏"), radius: 0)
        case let .fire(b, at, radius, drag): return Shape(anchor: at, label: k(b), radius: drag ? radius : 0)
        case let .spellCancel(b, at): return Shape(anchor: at, label: L("\(k(b)) 取消"), radius: 0)
        case let .rightWalk(b, center, radius): return Shape(anchor: center, label: L("\(k(b)) 行走"), radius: radius)
        case let .observe(b, at, radius, _): return Shape(anchor: at, label: L("\(k(b)) 观察"), radius: radius)
        case let .zoomKeys(i, o, center): return Shape(anchor: center, label: L("\(k(i))放大 \(k(o))缩小"), radius: 0)
        case let .gravity(u, d, l, r): return Shape(anchor: c.anchor, label: L("重力"), radius: 0, directions: [u, d, l, r].map(k))
        }
    }
}
