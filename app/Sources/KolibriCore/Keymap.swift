import Foundation

/// Point in normalized guest-screen space (0...1 on each axis), so a keymap
/// survives resolution changes.
public struct NPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    func clamped() -> NPoint { NPoint(min(max(x, 0), 1), min(max(y, 0), 1)) }
    static func + (a: NPoint, b: NPoint) -> NPoint { NPoint(a.x + b.x, a.y + b.y) }
}

/// What physical input triggers a control.
public enum Binding: Codable, Hashable, Sendable {
    /// macOS virtual key code (kVK_*).
    case key(UInt16)
    /// Mouse button: 0 left, 1 right, 2 middle, 3+ extra.
    case mouse(Int)
    /// Gamepad element name from GameController (e.g. "Button A", "Right Trigger").
    case pad(String)

    public var isPad: Bool { if case .pad = self { return true } else { return false } }
}

/// How a button turns a key press into finger input ("点发方式").
public enum TriggerMode: Codable, Hashable, Sendable {
    /// 按住：key down = finger down, key up = finger up.
    case hold
    /// 单点：one short tap per press, however long the key is held.
    case click(holdMs: Int)
    /// 双击：two taps per press.
    case doubleClick(holdMs: Int, gapMs: Int)
    /// 连发：tap repeatedly at `hz` while the key is held.
    case turbo(hz: Double)
    /// 连击：one press fires `count` taps at `hz`.
    case burst(count: Int, hz: Double)
    /// 开关：first press puts the finger down, second press lifts it.
    case toggle
    /// 长按：one press holds the finger down for `ms`, then lifts.
    case longPress(ms: Int)

    public static let all: [TriggerMode] = [.hold, .click(holdMs: 40), .doubleClick(holdMs: 40, gapMs: 60),
                                            .turbo(hz: 12), .burst(count: 10, hz: 15), .toggle, .longPress(ms: 600)]

    public var title: String {
        switch self {
        case .hold: return L("按住")
        case .click: return L("单点")
        case .doubleClick: return L("双击")
        case .turbo: return L("连发")
        case .burst: return L("连击")
        case .toggle: return L("开关")
        case .longPress: return L("长按")
        }
    }

    /// Mode family, ignoring parameters (for pickers).
    public var kind: Int {
        switch self {
        case .hold: return 0
        case .click: return 1
        case .doubleClick: return 2
        case .turbo: return 3
        case .burst: return 4
        case .toggle: return 5
        case .longPress: return 6
        }
    }
}

/// Skill-cast behaviour.
public struct SkillOptions: Codable, Hashable, Sendable {
    /// Aim with the movement joystick's direction instead of the mouse.
    public var followJoystick: Bool
    /// Cast when the key is released (otherwise cast immediately on press: a tap).
    public var castOnRelease: Bool

    public init(followJoystick: Bool = false, castOnRelease: Bool = true) {
        self.followJoystick = followJoystick
        self.castOnRelease = castOnRelease
    }
}

/// One step of a macro script (click_rel / press_rel / release_rel /
/// curve_rel / sleep / keyboard_press|release / start_loop / stop_loop).
public enum MacroAction: Codable, Hashable, Sendable {
    case tap(NPoint, holdMs: Int)
    /// Finger `finger` (0...7) down / up — lets a macro hold several fingers.
    case down(NPoint, finger: Int)
    case up(finger: Int)
    /// Drag one finger along `path` in `ms`.
    case swipe([NPoint], ms: Int)
    case sleep(ms: Int)
    /// Press/release a guest key (macOS key code, forwarded as a real key event).
    case key(UInt16, down: Bool)
    /// Everything between loopStart and loopEnd repeats while the trigger is held.
    case loopStart
    case loopEnd
}

/// One on-screen control. Each control owns stable touch identifiers so
/// several controls can be held at once (true multi-touch).
public enum Control: Codable, Hashable, Sendable {
    /// 点击/连击: a screen button with a trigger mode.
    case button(binding: Binding, at: NPoint, mode: TriggerMode)
    /// 方向摇杆: four keys or a gamepad stick drive a thumbstick.
    case joystick(up: Binding, down: Binding, left: Binding, right: Binding, center: NPoint, radius: Double, stick: String?)
    /// 鼠标视角: relative mouse (pointer locked) or a stick drags a finger around `center`.
    case aim(center: NPoint, radius: Double, sensitivity: Double, stick: String?)
    /// 键盘视角: four keys pan the camera finger at `speed` (screen widths/s).
    case lookKeys(up: Binding, down: Binding, left: Binding, right: Binding, center: NPoint, radius: Double, speed: Double)
    /// 技能: press = finger on the button, steer inside `radius`, release casts.
    case skill(binding: Binding, at: NPoint, radius: Double, options: SkillOptions)
    /// 滑动: replays a drag along `path` (absolute points) in `durationMs`.
    case swipe(binding: Binding, path: [NPoint], durationMs: Int)
    /// 宏: scripted actions on press, optional actions on release.
    case macro(binding: Binding, press: [MacroAction], release: [MacroAction])
    /// 开火/攻击键: finger on the fire button; with `dragAim` the mouse
    /// steers that finger while firing (fire-and-turn), inside `radius`.
    case fire(binding: Binding, at: NPoint, radius: Double, dragAim: Bool)
    /// 取消施法: drags a held skill onto the cancel area and lets go.
    case spellCancel(binding: Binding, at: NPoint)
    /// 右键行走: while held, the walk stick points from the screen
    /// center (the hero) toward the cursor.
    case rightWalk(binding: Binding, center: NPoint, radius: Double)
    /// 观察键: hold to put a finger on the camera area; the mouse drags it.
    case observe(binding: Binding, at: NPoint, radius: Double, sensitivity: Double)
    /// 缩放键: two keys pinch in / out around `center`.
    case zoomKeys(zoomIn: Binding, zoomOut: Binding, center: NPoint)
    /// 重力感应: four keys tilt the device (accelerometer).
    case gravity(up: Binding, down: Binding, left: Binding, right: Binding)

    /// Where the control is drawn in hints/editor.
    public var anchor: NPoint {
        switch self {
        case let .button(_, at, _), let .skill(_, at, _, _), let .fire(_, at, _, _), let .spellCancel(_, at),
             let .observe(_, at, _, _): return at
        case let .rightWalk(_, c, _), let .zoomKeys(_, _, c): return c
        case .gravity: return NPoint(0.5, 0.12)
        case let .joystick(_, _, _, _, c, _, _), let .aim(c, _, _, _), let .lookKeys(_, _, _, _, c, _, _): return c
        case let .swipe(_, path, _): return path.first ?? NPoint(0.5, 0.5)
        case let .macro(_, press, _):
            for a in press {
                switch a {
                case let .tap(p, _), let .down(p, _): return p
                case let .swipe(path, _): if let p = path.first { return p }
                default: continue
                }
            }
            return NPoint(0.5, 0.1)
        }
    }

    /// Bindings that trigger this control directly (sticks are matched separately).
    public var triggers: [Binding] {
        switch self {
        case let .button(b, _, _), let .skill(b, _, _, _), let .swipe(b, _, _), let .macro(b, _, _),
             let .fire(b, _, _, _), let .spellCancel(b, _), let .rightWalk(b, _, _), let .observe(b, _, _, _): return [b]
        case let .joystick(u, d, l, r, _, _, _), let .lookKeys(u, d, l, r, _, _, _), let .gravity(u, d, l, r): return [u, d, l, r]
        case let .zoomKeys(i, o, _): return [i, o]
        case .aim: return []
        }
    }
}

/// What happens to input the keymap does not use.
public struct Passthrough: Codable, Hashable, Sendable {
    /// Unmapped left click / drag becomes a real finger.
    public var mouse = true
    /// Unmapped keys reach Android as key events (typing in chat boxes).
    public var keyboard = true
    /// Scroll: `true` = scroll/drag gesture, `false` = use `wheelZoom` if set.
    public var wheel = true
    public init() {}
}

/// Scroll wheel → two-finger pinch around `center`.
public struct WheelZoom: Codable, Hashable, Sendable {
    public var center: NPoint
    /// Finger travel per wheel notch, normalized width units.
    public var stepDistance: Double
    public init(center: NPoint = NPoint(0.5, 0.5), stepDistance: Double = 0.02) {
        self.center = center
        self.stepDistance = stepDistance
    }
}

/// Per-control extras from the editor.
public struct ControlExtra: Codable, Hashable, Sendable {
    /// Short note drawn instead of the key name in hints (≤ 5 characters suggested).
    public var note: String
    /// Draw this control's hint while playing.
    public var showHint: Bool
    /// 滑动键位 · 直线轨迹: drawn paths collapse to start → end.
    public var straightLine: Bool
    /// Where hint-only controls without a screen position (重力感应) are drawn.
    public var position: NPoint?

    public init(note: String = "", showHint: Bool = true, straightLine: Bool = false, position: NPoint? = nil) {
        self.note = note
        self.showHint = showHint
        self.straightLine = straightLine
        self.position = position
    }

    enum CodingKeys: String, CodingKey { case note, showHint, straightLine, position }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        showHint = try c.decodeIfPresent(Bool.self, forKey: .showHint) ?? true
        straightLine = try c.decodeIfPresent(Bool.self, forKey: .straightLine) ?? false
        position = try c.decodeIfPresent(NPoint.self, forKey: .position)
    }
}

public struct Keymap: Codable, Hashable, Sendable {
    public var name: String
    /// Android package this keymap belongs to (nil = global).
    public var package: String?
    public var controls: [Control]
    /// Key that toggles pointer lock (mouse-look). User-chosen; nil = none.
    public var aimToggle: Binding?
    public var passthrough: Passthrough
    public var wheelZoom: WheelZoom?
    /// Hint overlay opacity 0...1.
    public var hintOpacity: Double
    /// Parallel to `controls` (may be shorter; missing entries are defaults).
    public var extras: [ControlExtra]

    public func extra(_ i: Int) -> ControlExtra { extras.indices.contains(i) ? extras[i] : ControlExtra() }

    public mutating func setExtra(_ i: Int, _ e: ControlExtra) {
        while extras.count <= i { extras.append(ControlExtra()) }
        extras[i] = e
    }

    /// Remove a control and keep `extras` aligned.
    public mutating func removeControl(at i: Int) {
        controls.remove(at: i)
        if extras.indices.contains(i) { extras.remove(at: i) }
    }

    public init(name: String, package: String? = nil, controls: [Control], aimToggle: Binding? = nil,
                passthrough: Passthrough = Passthrough(), wheelZoom: WheelZoom? = nil, hintOpacity: Double = 0.7) {
        self.name = name
        self.package = package
        self.controls = controls
        self.aimToggle = aimToggle
        self.passthrough = passthrough
        self.wheelZoom = wheelZoom
        self.hintOpacity = hintOpacity
        self.extras = []
    }

    // Tolerate older files that lack the newer fields.
    enum CodingKeys: String, CodingKey { case name, package, controls, aimToggle, passthrough, wheelZoom, hintOpacity, extras }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        package = try c.decodeIfPresent(String.self, forKey: .package)
        controls = try c.decode([Control].self, forKey: .controls)
        aimToggle = try c.decodeIfPresent(Binding.self, forKey: .aimToggle)
        passthrough = try c.decodeIfPresent(Passthrough.self, forKey: .passthrough) ?? Passthrough()
        wheelZoom = try c.decodeIfPresent(WheelZoom.self, forKey: .wheelZoom)
        hintOpacity = try c.decodeIfPresent(Double.self, forKey: .hintOpacity) ?? 0.7
        extras = try c.decodeIfPresent([ControlExtra].self, forKey: .extras) ?? []
    }
}

/// A finger state to forward to the guest. pressure 0 = lifted.
public struct TouchPoint: Hashable, Sendable {
    public var id: Int32
    public var x: Int32
    public var y: Int32
    public var down: Bool

    public init(id: Int32, x: Int32, y: Int32, down: Bool) {
        self.id = id
        self.x = x
        self.y = y
        self.down = down
    }
}
