import Foundation

/// Turns keyboard / mouse / gamepad input into multi-touch frames.
///
/// Pure state machine: callers feed events and get back the touches that
/// changed. It never talks to the emulator, which keeps it unit-testable and
/// lets the frontend batch everything into one `InputEvent` per frame.
/// Timed behaviour (clicks, bursts, swipes, macros) runs on per-control
/// timelines advanced by `tick(now:)`.
public final class KeymapEngine {
    public private(set) var keymap: Keymap
    public var screenWidth: Int
    public var screenHeight: Int
    /// Guest key events produced by macros (macOS key code, down?).
    public var onKey: ((UInt16, Bool) -> Void)?
    /// Device tilt from 重力感应 keys, each axis -1...1 (x right, y toward the user).
    public var onTilt: ((Double, Double) -> Void)?

    private static let slotsPerControl: Int32 = 8
    private static let zoomBase: Int32 = 1000

    private var held: Set<Binding> = []
    private var active: [Int32: NPoint] = [:]
    private var aimOffset: [Int: (Double, Double)] = [:]
    private var skillOffset: [Int: (Double, Double)] = [:]
    private var sticks: [String: (Double, Double)] = [:]
    private var turboStart: [Int: TimeInterval] = [:]
    private var toggled: Set<Int> = []
    private var runs: [Int: Run] = [:]
    private var lookLast: TimeInterval?
    private var zoom: (spread: Double, lastEvent: TimeInterval)?
    /// Last absolute cursor position (for 右键行走).
    private var pointer: NPoint?
    private var tilt: (Double, Double) = (0, 0)
    /// Order of key presses, so opposite movement keys resolve to the last one pressed.
    private var pressSeq: [Binding: Int] = [:]
    private var seq = 0
    /// Movement-stick fingers sliding toward their direction (see `updateJoystick`).
    private var glides: [Int: Glide] = [:]
    /// Time of the latest event, for inputs that carry no timestamp (gamepad sticks).
    private var clock: TimeInterval = 0

    /// 轮盘 timing: land on the
    /// stick centre, wait 8 ms, then slide to the direction in 6 steps of 16 ms.
    private static let glideSteps = 6
    private static let glidePeriod = 0.016
    private static let glideFirstWait = 0.008

    private struct Glide {
        var at: NPoint
        var target: NPoint
        var stepsLeft: Int
        var nextAt: TimeInterval
    }

    // MARK: Timeline

    private enum Op {
        case down(Int32, NPoint), move(Int32, NPoint), up(Int32)
        case wait(Double), key(UInt16, Bool), loopStart, loopEnd
    }

    private struct Run {
        var ops: [Op]
        var pc = 0
        var nextAt: TimeInterval
        var loopAt: Int?
        let binding: Binding?
    }

    public init(keymap: Keymap, screenWidth: Int, screenHeight: Int) {
        self.keymap = keymap
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    public func load(_ keymap: Keymap) -> [TouchPoint] {
        // Same scheme again (e.g. the foreground check re-resolved it): keep every finger.
        if keymap == self.keymap { return [] }
        let lifted = releaseAll()
        self.keymap = keymap
        return lifted
    }

    // MARK: - Events

    public func press(_ b: Binding, now: TimeInterval) -> [TouchPoint] {
        guard !held.contains(b) else { return [] }
        held.insert(b)
        clock = now
        seq += 1
        pressSeq[b] = seq
        var out: [TouchPoint] = []
        for (i, c) in keymap.controls.enumerated() where c.triggers.contains(b) {
            switch c {
            case let .button(_, at, mode):
                out += pressButton(i, at: at, mode: mode, now: now)
            case .joystick:
                out += updateJoystick(i, now: now)
                out += refreshFollowingSkills()
            case .lookKeys:
                if lookLast == nil { lookLast = now }
            case let .skill(_, at, _, opts):
                if opts.castOnRelease {
                    skillOffset[i] = (0, 0)
                    out += set(id(i), at)
                    out += updateSkillFromJoystick(i)
                } else {
                    out += start(i, ops: tapOps(i, at, holdMs: 40), now: now, binding: b)
                }
            case let .swipe(_, path, ms):
                out += start(i, ops: swipeOps(i, path, ms: ms), now: now, binding: b)
            case let .macro(_, pressActions, _):
                out += start(i, ops: compile(i, pressActions), now: now, binding: b)
            case let .fire(_, at, _, _):
                aimOffset[i] = (0, 0)
                out += set(id(i), at)
            case let .spellCancel(_, at):
                // Drag every held skill onto the cancel area, then let go.
                for j in skillOffset.keys.sorted() {
                    out += set(id(j), at) + lift(id(j))
                    skillOffset[j] = nil
                }
            case .rightWalk:
                out += updateRightWalk(i)
            case let .observe(_, at, _, _):
                aimOffset[i] = (0, 0)
                out += set(id(i), at)
            case let .zoomKeys(zi, _, center):
                out += pinch(center: center, step: 0.03, notches: b == zi ? 3 : -3, now: now)
            case .gravity:
                emitTilt()
            case .aim:
                break
            }
        }
        return out
    }

    public func release(_ b: Binding, now: TimeInterval) -> [TouchPoint] {
        guard held.remove(b) != nil else { return [] }
        clock = now
        var out: [TouchPoint] = []
        for (i, c) in keymap.controls.enumerated() where c.triggers.contains(b) {
            switch c {
            case let .button(_, _, mode):
                switch mode {
                case .hold: out += lift(id(i))
                case .turbo: turboStart[i] = nil; out += lift(id(i))
                default: break   // timed or latched
                }
            case .joystick:
                out += updateJoystick(i, now: now)
                out += refreshFollowingSkills()
            case .lookKeys:
                if !lookKeysHeld(i) { aimOffset[i] = nil; out += lift(id(i)) }
            case let .skill(_, _, _, opts) where opts.castOnRelease:
                skillOffset[i] = nil
                out += lift(id(i))
            case .fire, .observe, .rightWalk:
                aimOffset[i] = nil
                out += lift(id(i))
            case .gravity:
                emitTilt()
            case let .macro(_, _, releaseActions):
                if !releaseActions.isEmpty {
                    // Release script runs after (and replaces) any looping press script.
                    out += start(i, ops: compile(i, releaseActions), now: now, binding: nil, keepFingers: true)
                }
            default:
                break
            }
        }
        return out
    }

    /// Relative mouse motion in screen pixels (only meaningful while the pointer is locked).
    public func mouseMoved(dx: Double, dy: Double) -> [TouchPoint] {
        // A held (mouse-steered) skill takes the mouse first; aim pauses while casting.
        for (i, c) in keymap.controls.enumerated() {
            if case let .skill(_, at, radius, opts) = c, !opts.followJoystick, var off = skillOffset[i] {
                off.0 += dx / Double(screenWidth)
                off.1 += dy / Double(screenHeight)
                off = clampToRadius(off, radius)
                skillOffset[i] = off
                return set(id(i), at + NPoint(off.0, off.1))
            }
        }
        // 观察键 held: the camera finger follows the mouse and stays inside its area.
        for (i, c) in keymap.controls.enumerated() {
            if case let .observe(_, at, radius, sens) = c, var off = aimOffset[i] {
                off.0 += dx * sens / Double(screenWidth)
                off.1 += dy * sens / Double(screenHeight)
                off = clampToRadius(off, radius)
                aimOffset[i] = off
                return set(id(i), at + NPoint(off.0, off.1))
            }
        }
        // Fire-and-turn: the fire finger takes over aiming while held.
        for (i, c) in keymap.controls.enumerated() {
            if case let .fire(_, at, radius, true) = c, aimOffset[i] != nil {
                return moveAim(i, center: at, radius: radius, dx: dx / Double(screenWidth), dy: dy / Double(screenHeight))
            }
        }
        var out: [TouchPoint] = []
        for (i, c) in keymap.controls.enumerated() {
            guard case let .aim(center, radius, sens, _) = c else { continue }
            out += moveAim(i, center: center, radius: radius, dx: dx * sens / Double(screenWidth), dy: dy * sens / Double(screenHeight))
        }
        return out
    }

    /// Whether held controls want relative mouse motion even without pointer lock
    /// (观察键, fire-and-turn, mouse-steered skills).
    public var capturesMouse: Bool {
        keymap.controls.indices.contains { i in
            switch keymap.controls[i] {
            case .observe: return aimOffset[i] != nil
            case .fire(_, _, _, true): return aimOffset[i] != nil
            case let .skill(_, _, _, o): return !o.followJoystick && skillOffset[i] != nil
            default: return false
            }
        }
    }

    /// Absolute cursor position (unlocked pointer), for 右键行走.
    public func pointerMoved(to p: NPoint) -> [TouchPoint] {
        pointer = p
        return keymap.controls.indices.flatMap { i -> [TouchPoint] in
            if case let .rightWalk(b, _, _) = keymap.controls[i], held.contains(b) { return updateRightWalk(i) }
            return []
        }
    }

    /// Scroll wheel: pinch zoom when the keymap defines it. `notches` > 0 zooms in.
    public func wheel(notches: Double, now: TimeInterval) -> [TouchPoint] {
        guard let z = keymap.wheelZoom, notches != 0 else { return [] }
        return pinch(center: z.center, step: z.stepDistance, notches: notches, now: now)
    }

    private func pinch(center: NPoint, step: Double, notches: Double, now: TimeInterval) -> [TouchPoint] {
        var out: [TouchPoint] = []
        var spread = zoom?.spread ?? 0.04
        if zoom == nil {
            out += set(Self.zoomBase, center + NPoint(-spread, 0))
            out += set(Self.zoomBase + 1, center + NPoint(spread, 0))
        }
        spread = min(max(spread + notches * step, 0.01), 0.45)
        zoom = (spread, now)
        out += set(Self.zoomBase, center + NPoint(-spread, 0))
        out += set(Self.zoomBase + 1, center + NPoint(spread, 0))
        return out
    }

    /// Analog stick value in -1...1 (y down positive), keyed by stick name ("left"/"right").
    public func stick(_ name: String, x: Double, y: Double, dt: Double) -> [TouchPoint] {
        sticks[name] = (x, y)
        var out: [TouchPoint] = []
        for (i, c) in keymap.controls.enumerated() {
            switch c {
            case let .joystick(_, _, _, _, _, _, s) where s == name:
                out += updateJoystick(i, now: clock)
            case let .aim(center, radius, sens, s) where s == name:
                if hypot(x, y) < 0.12 {
                    if aimOffset[i] != nil { aimOffset[i] = nil; out += lift(id(i)) }
                } else {
                    let speed = 1.2 * sens * dt   // ~1.2 screen widths/s at full tilt
                    out += moveAim(i, center: center, radius: radius, dx: x * speed, dy: y * speed)
                }
            default:
                break
            }
        }
        out += refreshFollowingSkills()
        return out
    }

    /// Advance timed controls. Call once per display frame.
    public func tick(now: TimeInterval) -> [TouchPoint] {
        clock = now
        var out: [TouchPoint] = []
        for i in glides.keys.sorted() { out += stepGlide(i, now: now) }
        for i in turboStart.keys.sorted() {
            if case let .button(_, at, .turbo(hz)) = keymap.controls[i], let t0 = turboStart[i] {
                let period = 1 / max(hz, 1)
                let down = (now - t0).truncatingRemainder(dividingBy: period) < period / 2
                out += down ? set(id(i), at) : lift(id(i))
            }
        }
        for i in runs.keys.sorted() { out += step(i, now: now) }
        out += tickLookKeys(now)
        if let z = zoom, now - z.lastEvent > 0.25 {   // pinch ends shortly after scrolling stops
            out += lift(Self.zoomBase) + lift(Self.zoomBase + 1)
            zoom = nil
        }
        return out
    }

    /// Lift every finger (focus lost, keymap switched, editor opened).
    public func releaseAll() -> [TouchPoint] {
        let out = active.keys.sorted().map { TouchPoint(id: $0, x: 0, y: 0, down: false) }
        active.removeAll(); held.removeAll(); aimOffset.removeAll(); skillOffset.removeAll()
        turboStart.removeAll(); runs.removeAll(); sticks.removeAll(); toggled.removeAll(); glides.removeAll()
        lookLast = nil; zoom = nil
        if tilt != (0, 0) { tilt = (0, 0); onTilt?(0, 0) }
        return out
    }

    /// Pointer unlocked: lift only the mouse-driven fingers (aim, observe, fire-and-turn,
    /// mouse-steered skills). Movement keys and held buttons stay down,.
    public func releaseMouseControls() -> [TouchPoint] {
        var out: [TouchPoint] = []
        for i in keymap.controls.indices {
            switch keymap.controls[i] {
            case .aim, .observe, .fire(_, _, _, true):
                if aimOffset.removeValue(forKey: i) != nil { out += lift(id(i)) }
            case let .skill(_, _, _, o) where !o.followJoystick:
                if skillOffset.removeValue(forKey: i) != nil { out += lift(id(i)) }
            default:
                break
            }
        }
        return out
    }

    public var activeTouches: [TouchPoint] {
        active.keys.sorted().map { k in let p = px(active[k]!); return TouchPoint(id: k, x: p.0, y: p.1, down: true) }
    }

    // MARK: - Buttons & timelines

    private func pressButton(_ i: Int, at: NPoint, mode: TriggerMode, now: TimeInterval) -> [TouchPoint] {
        switch mode {
        case .hold:
            return set(id(i), at)
        case .turbo:
            turboStart[i] = now
            return tick(now: now)
        case .toggle:
            if toggled.remove(i) != nil { return lift(id(i)) }
            toggled.insert(i)
            return set(id(i), at)
        case let .click(h):
            return start(i, ops: tapOps(i, at, holdMs: h), now: now, binding: nil)
        case let .doubleClick(h, gap):
            return start(i, ops: tapOps(i, at, holdMs: h) + [.wait(Double(gap) / 1000)] + tapOps(i, at, holdMs: h), now: now, binding: nil)
        case let .burst(count, hz):
            let period = 1 / max(hz, 1)
            var ops: [Op] = []
            for _ in 0..<max(count, 1) { ops += tapOps(i, at, holdMs: Int(period * 500)) + [.wait(period / 2)] }
            return start(i, ops: ops, now: now, binding: nil)
        case let .longPress(ms):
            return start(i, ops: tapOps(i, at, holdMs: ms), now: now, binding: nil)
        }
    }

    private func tapOps(_ i: Int, _ p: NPoint, holdMs: Int, finger: Int32 = 0) -> [Op] {
        [.down(id(i, sub: finger), p), .wait(Double(max(holdMs, 16)) / 1000), .up(id(i, sub: finger))]
    }

    private func swipeOps(_ i: Int, _ path: [NPoint], ms: Int, finger: Int32 = 0) -> [Op] {
        guard let first = path.first else { return [] }
        let f = id(i, sub: finger)
        // Resample to ~60 Hz so long drags stay smooth regardless of point count.
        let steps = max(Int(Double(ms) / 16.0), path.count - 1, 1)
        var ops: [Op] = [.down(f, first)]
        for s in 1...steps {
            ops += [.wait(Double(ms) / 1000 / Double(steps)), .move(f, Self.interpolate(path, Double(s) / Double(steps)))]
        }
        return ops + [.wait(0.016), .up(f)]
    }

    private static func interpolate(_ path: [NPoint], _ t: Double) -> NPoint {
        guard path.count > 1 else { return path.first ?? NPoint(0, 0) }
        let pos = t * Double(path.count - 1)
        let k = min(Int(pos), path.count - 2)
        let f = pos - Double(k)
        return NPoint(path[k].x + (path[k + 1].x - path[k].x) * f, path[k].y + (path[k + 1].y - path[k].y) * f)
    }

    private func compile(_ i: Int, _ actions: [MacroAction]) -> [Op] {
        var ops: [Op] = []
        for a in actions {
            switch a {
            case let .tap(p, h): ops += tapOps(i, p, holdMs: h, finger: 7)
            case let .down(p, f): ops.append(.down(id(i, sub: Int32(f % 7)), p))
            case let .up(f): ops.append(.up(id(i, sub: Int32(f % 7))))
            case let .swipe(path, ms): ops += swipeOps(i, path, ms: ms, finger: 6)
            case let .sleep(ms): ops.append(.wait(Double(ms) / 1000))
            case let .key(code, down): ops.append(.key(code, down))
            case .loopStart: ops.append(.loopStart)
            case .loopEnd: ops.append(.loopEnd)
            }
        }
        return ops
    }

    private func start(_ i: Int, ops: [Op], now: TimeInterval, binding: Binding?, keepFingers: Bool = false) -> [TouchPoint] {
        var out: [TouchPoint] = []
        if !keepFingers {
            // A re-press restarts cleanly: lift anything the previous run left down.
            for sub in 0..<Self.slotsPerControl { out += lift(id(i, sub: sub)) }
        }
        runs[i] = Run(ops: ops, nextAt: now, binding: binding)
        return out + step(i, now: now)
    }

    private func step(_ i: Int, now: TimeInterval) -> [TouchPoint] {
        guard var r = runs[i] else { return [] }
        var out: [TouchPoint] = []
        while r.pc < r.ops.count, now >= r.nextAt {
            switch r.ops[r.pc] {
            case let .down(f, p), let .move(f, p): out += set(f, p)
            case let .up(f): out += lift(f)
            case let .wait(s): r.nextAt += s
            case let .key(code, down): onKey?(code, down)
            case .loopStart: r.loopAt = r.pc
            case .loopEnd:
                if let l = r.loopAt, let b = r.binding, held.contains(b) {
                    r.pc = l   // keeps looping while the trigger is held
                    if r.nextAt <= now { r.nextAt = now + 0.001 }   // never spin without a wait
                }
            }
            r.pc += 1
        }
        if r.pc >= r.ops.count { runs[i] = nil } else { runs[i] = r }
        return out
    }

    // MARK: - Sticks, aim, skills

    private var aspect: Double { Double(screenHeight) / Double(screenWidth) }

    private func id(_ control: Int, sub: Int32 = 0) -> Int32 {
        Int32(control) * Self.slotsPerControl + sub
    }

    private func px(_ p: NPoint) -> (Int32, Int32) {
        let c = p.clamped()
        return (Int32(min((c.x * Double(screenWidth)).rounded(), Double(screenWidth - 1))),
                Int32(min((c.y * Double(screenHeight)).rounded(), Double(screenHeight - 1))))
    }

    private func set(_ id: Int32, _ p: NPoint) -> [TouchPoint] {
        if active[id] == p { return [] }
        active[id] = p
        let (x, y) = px(p)
        return [TouchPoint(id: id, x: x, y: y, down: true)]
    }

    private func lift(_ id: Int32) -> [TouchPoint] {
        guard let p = active.removeValue(forKey: id) else { return [] }
        let (x, y) = px(p)
        return [TouchPoint(id: id, x: x, y: y, down: false)]
    }

    private func clampToRadius(_ off: (Double, Double), _ radius: Double) -> (Double, Double) {
        let len = hypot(off.0, off.1 * aspect)
        return len > radius ? (off.0 * radius / len, off.1 * radius / len) : off
    }

    /// Current movement direction (keys or left stick), unit-ish vector or nil.
    private func joystickVector(_ i: Int) -> (Double, Double)? {
        guard case let .joystick(u, d, l, r, _, _, s) = keymap.controls[i] else { return nil }
        var vx = axis(l, r)
        var vy = axis(u, d)
        if let s, let v = sticks[s], hypot(v.0, v.1) > 0.12 { vx = v.0; vy = v.1 }
        let len = hypot(vx, vy)
        guard len > 0 else { return nil }
        let k = min(len, 1) / len
        return (vx * k, vy * k)
    }

    /// Opposite keys held together: the one pressed last wins, so
    /// holding A and tapping D turns right instead of cancelling out and lifting the finger.
    private func axis(_ negative: Binding, _ positive: Binding) -> Double {
        switch (held.contains(negative), held.contains(positive)) {
        case (true, true): return (pressSeq[positive] ?? 0) > (pressSeq[negative] ?? 0) ? 1 : -1
        case (true, false): return -1
        case (false, true): return 1
        case (false, false): return 0
        }
    }

    /// The finger never jumps: a fresh press lands on the stick centre and slides out,
    /// and a new direction slides over from where the finger is. A touch-down already
    /// on the rim, or a jump within one frame, makes games treat it as a tap outside the
    /// stick or re-centre a floating stick under the finger, and the stick stops responding.
    private func updateJoystick(_ i: Int, now: TimeInterval) -> [TouchPoint] {
        guard case let .joystick(_, _, _, _, center, radius, s) = keymap.controls[i] else { return [] }
        guard let v = joystickVector(i) else {
            glides[i] = nil
            return lift(id(i))
        }
        // radius is in normalized width units; scale y by aspect so the stick stays circular.
        let target = center + NPoint(v.0 * radius, v.1 * radius / aspect)
        // A gamepad stick already moves continuously: after landing, follow it directly.
        let analog = s.flatMap { sticks[$0] }.map { hypot($0.0, $0.1) > 0.12 } ?? false
        guard let at = active[id(i)] else {
            let steps = analog ? 1 : Self.glideSteps
            glides[i] = Glide(at: center, target: target, stepsLeft: steps, nextAt: now + Self.glideFirstWait)
            return set(id(i), center)
        }
        if analog, glides[i]?.stepsLeft ?? 0 == 0 {
            glides[i] = nil
            return set(id(i), target)
        }
        var g = glides[i] ?? Glide(at: at, target: target, stepsLeft: 0, nextAt: now)
        guard g.target != target else { return [] }
        g.target = target
        // Mid-slide: keep the remaining steps (re-aimed); settled: a new slide starts now.
        if g.stepsLeft == 0 { g.stepsLeft = Self.glideSteps; g.nextAt = now }
        glides[i] = g
        return stepGlide(i, now: now)
    }

    private func stepGlide(_ i: Int, now: TimeInterval) -> [TouchPoint] {
        guard var g = glides[i], g.stepsLeft > 0, now >= g.nextAt else { return [] }
        let k = 1 / Double(g.stepsLeft)
        g.at = g.stepsLeft == 1 ? g.target : NPoint(g.at.x + (g.target.x - g.at.x) * k, g.at.y + (g.target.y - g.at.y) * k)
        g.stepsLeft -= 1
        g.nextAt = max(g.nextAt + Self.glidePeriod, now)
        glides[i] = g
        return set(id(i), g.at)
    }

    private func updateSkillFromJoystick(_ i: Int) -> [TouchPoint] {
        guard case let .skill(_, at, radius, opts) = keymap.controls[i], opts.followJoystick, skillOffset[i] != nil else { return [] }
        let v = keymap.controls.indices.lazy.compactMap { self.joystickVector($0) }.first ?? (0, 0)
        let off = (v.0 * radius, v.1 * radius / aspect)
        skillOffset[i] = off
        return set(id(i), at + NPoint(off.0, off.1))
    }

    private func refreshFollowingSkills() -> [TouchPoint] {
        keymap.controls.indices.flatMap { updateSkillFromJoystick($0) }
    }

    private func moveAim(_ i: Int, center: NPoint, radius: Double, dx: Double, dy: Double) -> [TouchPoint] {
        var out: [TouchPoint] = []
        var off = aimOffset[i] ?? (0, 0)
        if aimOffset[i] == nil { out += set(id(i), center) }
        off.0 += dx
        off.1 += dy
        if hypot(off.0, off.1 * aspect) > radius {
            // Ran out of room: lift and re-land at center, carrying the overshoot.
            out += lift(id(i))
            off = (dx, dy)
            out += set(id(i), center)
        }
        aimOffset[i] = off
        out += set(id(i), center + NPoint(off.0, off.1))
        return out
    }

    private func updateRightWalk(_ i: Int) -> [TouchPoint] {
        guard case let .rightWalk(b, center, radius) = keymap.controls[i], held.contains(b), let p = pointer else { return [] }
        // Direction in screen pixels from the hero (screen center) to the cursor.
        let vx = (p.x - 0.5) * Double(screenWidth), vy = (p.y - 0.5) * Double(screenHeight)
        let len = hypot(vx, vy)
        var out: [TouchPoint] = []
        if active[id(i)] == nil { out += set(id(i), center) }
        guard len > 1 else { return out }
        out += set(id(i), center + NPoint(vx / len * radius, vy / len * radius / aspect))
        return out
    }

    private func emitTilt() {
        var t = (0.0, 0.0)
        for c in keymap.controls {
            guard case let .gravity(u, d, l, r) = c else { continue }
            t.0 += (held.contains(r) ? 1 : 0) - (held.contains(l) ? 1 : 0)
            t.1 += (held.contains(d) ? 1 : 0) - (held.contains(u) ? 1 : 0)
        }
        t = (min(max(t.0, -1), 1), min(max(t.1, -1), 1))
        if t != tilt { tilt = t; onTilt?(t.0, t.1) }
    }

    private func lookKeysHeld(_ i: Int) -> Bool {
        guard case let .lookKeys(u, d, l, r, _, _, _) = keymap.controls[i] else { return false }
        return [u, d, l, r].contains(where: held.contains)
    }

    private func tickLookKeys(_ now: TimeInterval) -> [TouchPoint] {
        guard let last = lookLast else { return [] }
        let dt = min(now - last, 0.05)
        lookLast = now
        var out: [TouchPoint] = []
        var any = false
        for (i, c) in keymap.controls.enumerated() {
            guard case let .lookKeys(u, d, l, r, center, radius, speed) = c, lookKeysHeld(i) else { continue }
            any = true
            let vx = (held.contains(r) ? 1.0 : 0) - (held.contains(l) ? 1.0 : 0)
            let vy = (held.contains(d) ? 1.0 : 0) - (held.contains(u) ? 1.0 : 0)
            if vx == 0 && vy == 0 { continue }
            out += moveAim(i, center: center, radius: radius, dx: vx * speed * dt, dy: vy * speed * dt / aspect)
        }
        if !any { lookLast = nil }
        return out
    }
}
