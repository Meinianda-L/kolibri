import AppKit
import SwiftUI
import KolibriCore

/// Keymap editing over the live game, with its own interaction model:
///
/// - right-click an empty spot → 添加键鼠按键 menu at that point; click an item to
///   place it there, or drag it (> 20 pt) onto the game button
/// - a new key is focused right away: the next key / mouse button / wheel / pad
///   button becomes its key (按下键盘或鼠标按键设置键值); click a key to rebind
/// - hover or focus shows ⚙ (settings) and × (delete); drag to move; the handle
///   beside a focused key adjusts its size (调整大小 / 调整施法范围)
/// - conflicting keys turn red and block saving
/// - top bar: 编辑方案：name · 清空 · 重置 · 重命名 · 教程 · 保存
struct KeymapEditor: View {
    @ObservedObject var session: GameSession
    let kind: SchemeKind

    @State private var draft = Keymap(name: "", controls: [])
    @State private var original = Keymap(name: "", controls: [])
    @State private var savedName: String?
    @State private var focused: Int?
    /// Which key of a multi-key control is listening (方向键 up/down/left/right, 缩放 in/out).
    @State private var slot = 0
    @State private var hovered: Int?
    @State private var menuAt: CGPoint?
    @State private var dragging: Int?
    @State private var settingsFor: Int?
    @State private var curveStroke: [CGPoint] = []
    @State private var monitor: Any?
    @State private var dialog: Dialog?
    @State private var renameText = ""
    @State private var showHelp = false

    private enum Dialog: Identifiable {
        case clear, reset, rename, leave, empty, conflict
        var id: Self { self }
    }

    private var pad: Bool { kind == .gamepad }

    /// Fixed state for `--uisnap` renders (ImageRenderer never runs onAppear).
    struct Preview {
        var draft: Keymap
        var focused: Int? = nil
        var slot = 0
        var menuAt: CGPoint? = nil
        var settingsFor: Int? = nil
    }

    init(session: GameSession, kind: SchemeKind, preview: Preview? = nil) {
        self.session = session
        self.kind = kind
        if let p = preview {
            _draft = State(initialValue: p.draft)
            _original = State(initialValue: p.draft)
            _focused = State(initialValue: p.focused)
            _slot = State(initialValue: p.slot)
            _menuAt = State(initialValue: p.menuAt)
            _settingsFor = State(initialValue: p.settingsFor)
            _previewing = State(initialValue: true)
        }
    }

    @State private var previewing = false

    var body: some View {
        GeometryReader { geo in
            let r = fitRect(geo.size)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.45).allowsHitTesting(false)
                if !previewing {
                    CanvasMouse(onLeftDown: leftDown, onLeftDrag: { curveDrag($0) }, onLeftUp: { curveEnd(r) },
                                onRightDown: rightDown)
                }
                if draft.controls.isEmpty {
                    tip(L("点击鼠标右键添加按键键位")).position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else if let f = focused, draft.controls.indices.contains(f), ControlKind.of(draft.controls[f]) == .curve {
                    tip(L("按住鼠标左键开始滑动")).position(x: geo.size.width / 2, y: 70)
                }
                if !curveStroke.isEmpty {
                    Path { p in p.addLines(curveStroke) }.stroke(.yellow, lineWidth: 3).allowsHitTesting(false)
                }
                ForEach(Array(draft.controls.enumerated()), id: \.offset) { i, c in
                    KeyCap(control: c, extra: draft.extra(i), rect: r, aimToggle: draft.aimToggle,
                           state: focused == i ? .focused : (hovered == i ? .hover : .normal),
                           listeningSlot: focused == i ? slot : nil,
                           conflicts: conflicts,
                           onFocus: { s in focus(i, slot: s) },
                           onHover: { h in hovered = h ? i : (hovered == i ? nil : hovered) },
                           onMove: { p in move(i, to: p, r) },
                           onSettings: { settingsFor = i; focus(i, slot: 0) },
                           onDelete: { delete(i) },
                           onResize: { v in resize(i, v) },
                           onCount: { d in bump(i, d) })
                }
                if let i = settingsFor, draft.controls.indices.contains(i) {
                    settingsPanel(i).position(panelPosition(i, r, geo.size))
                }
                if let p = menuAt {
                    AddMenu(kind: kind, isTaken: taken,
                            onClick: { k in create(k, at: p, r) },
                            onDrag: { k, loc in dragCreate(k, loc, r) },
                            onDragEnd: { dragging = nil; menuAt = nil })
                        .position(menuPosition(p, geo.size))
                }
                editBar.padding(.top, 10)
            }
            .coordinateSpace(name: "canvas")
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .alert(alertTitle, isPresented: SwiftUI.Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } })) {
            alertButtons
        } message: { Text(alertMessage) }
        .sheet(isPresented: $showHelp) { help }
    }

    // MARK: Lifecycle

    private func begin() {
        if previewing { return }
        if session.editNew {
            draft = Keymap(name: KeymapStore.uniqueName(session.foregroundPackage, kind, L("自定义方案")),
                           package: session.foregroundPackage, controls: [])
            savedName = nil
        } else {
            draft = session.scheme(kind)
            savedName = session.schemes(kind).contains(draft.name) ? draft.name : nil
            if draft.name.isEmpty { draft.name = KeymapStore.uniqueName(session.foregroundPackage, kind, L("自定义方案")) }
        }
        original = draft
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown, .rightMouseDown, .scrollWheel]) { e in
            handleInput(e)
        }
        session.padListener = { b in
            guard focused != nil else { return }
            if !pad { session.show(L("请使用键鼠设置键位")); return }
            bind(b)
        }
    }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        session.padListener = nil
    }

    /// The next key, mouse button or wheel notch goes to the focused key.
    private func handleInput(_ e: NSEvent) -> NSEvent? {
        if NSApp.keyWindow?.firstResponder is NSTextView { return e }      // typing a 备注 / name
        if e.type == .keyDown, e.keyCode == 53 {                           // Esc: close menus, then drop focus
            if menuAt != nil || settingsFor != nil { menuAt = nil; settingsFor = nil } else { focused = nil }
            return nil
        }
        guard focused != nil else { return e }
        let b: KolibriCore.Binding?
        switch e.type {
        case .keyDown: b = e.isARepeat ? nil : .key(e.keyCode)
        case .flagsChanged: b = Self.modifierDown(e) ? .key(e.keyCode) : nil
        case .rightMouseDown: b = .mouse(1)
        case .otherMouseDown: b = .mouse(e.buttonNumber)
        case .scrollWheel:
            guard !e.hasPreciseScrollingDeltas, e.scrollingDeltaY != 0 else { return e }
            b = e.scrollingDeltaY > 0 ? .mouse(KeyNames.wheelUp) : .mouse(KeyNames.wheelDown)
        default: b = nil
        }
        guard let b else { return nil }
        if pad { session.show(L("请使用手柄设置键位")); return nil }
        bind(b)
        return nil
    }

    private static func modifierDown(_ e: NSEvent) -> Bool {
        switch Int(e.keyCode) {
        case 56, 60: return e.modifierFlags.contains(.shift)
        case 59, 62: return e.modifierFlags.contains(.control)
        case 58, 61: return e.modifierFlags.contains(.option)
        case 55, 54: return e.modifierFlags.contains(.command)
        default: return false
        }
    }

    // MARK: Canvas mouse

    private func leftDown(_ p: CGPoint) {
        menuAt = nil
        settingsFor = nil
        if let f = focused, draft.controls.indices.contains(f), ControlKind.of(draft.controls[f]) == .curve {
            curveStroke = [p]             // start drawing the swipe path
        } else {
            focused = nil
        }
    }

    private func rightDown(_ p: CGPoint) {
        // With a key focused, the right button is a key to bind (handled by the monitor).
        guard focused == nil else { return }
        settingsFor = nil
        menuAt = p
    }

    private func curveDrag(_ p: CGPoint) {
        guard !curveStroke.isEmpty else { return }
        if let last = curveStroke.last, hypot(p.x - last.x, p.y - last.y) < 6 { return }
        curveStroke.append(p)
    }

    private func curveEnd(_ r: CGRect) {
        defer { curveStroke = [] }
        guard let f = focused, curveStroke.count >= 2, case let .swipe(b, _, ms) = draft.controls[f] else { return }
        var pts = curveStroke.map { norm($0, r) }
        if pts.count > 24 { pts = stride(from: 0, to: pts.count, by: pts.count / 24 + 1).map { pts[$0] } + [pts.last!] }
        if draft.extra(f).straightLine { pts = [pts.first!, pts.last!] }
        draft.controls[f] = .swipe(binding: b, path: pts, durationMs: ms)
    }

    // MARK: Creating, focusing, binding

    private func taken(_ k: ControlKind) -> Bool {
        k.single && draft.controls.contains { ControlKind.of($0) == k }
    }

    private func create(_ k: ControlKind, at p: CGPoint, _ r: CGRect) {
        guard !taken(k) else { return }
        draft.controls.append(k.make(at: norm(p, r), pad: pad))
        menuAt = nil
        focus(draft.controls.count - 1, slot: 0)
    }

    /// Dragging a menu item out: the new key follows the cursor until release.
    private func dragCreate(_ k: ControlKind, _ loc: CGPoint, _ r: CGRect) {
        if let d = dragging {
            move(d, to: loc, r)
        } else if !taken(k) {
            draft.controls.append(k.make(at: norm(loc, r), pad: pad))
            dragging = draft.controls.count - 1
            focus(dragging!, slot: 0)
        }
    }

    private func focus(_ i: Int, slot s: Int) {
        focused = i
        slot = s
        menuAt = nil
    }

    private func bind(_ b: KolibriCore.Binding) {
        guard let i = focused, draft.controls.indices.contains(i) else { return }
        switch draft.controls[i] {
        case let .button(_, at, m): draft.controls[i] = .button(binding: b, at: at, mode: m)
        case let .skill(_, at, r, o): draft.controls[i] = .skill(binding: b, at: at, radius: r, options: o)
        case let .swipe(_, p, ms): draft.controls[i] = .swipe(binding: b, path: p, durationMs: ms)
        case let .macro(_, p, r): draft.controls[i] = .macro(binding: b, press: p, release: r)
        case let .fire(_, at, r, d): draft.controls[i] = .fire(binding: b, at: at, radius: r, dragAim: d)
        case let .spellCancel(_, at): draft.controls[i] = .spellCancel(binding: b, at: at)
        case let .rightWalk(_, cn, r): draft.controls[i] = .rightWalk(binding: b, center: cn, radius: r)
        case let .observe(_, at, r, s): draft.controls[i] = .observe(binding: b, at: at, radius: r, sensitivity: s)
        case .aim: draft.aimToggle = b          // 准心键: its key locks / unlocks the pointer
        case let .zoomKeys(zi, zo, cn):
            draft.controls[i] = slot == 0 ? .zoomKeys(zoomIn: b, zoomOut: zo, center: cn) : .zoomKeys(zoomIn: zi, zoomOut: b, center: cn)
            if slot == 0 { slot = 1 }
        case let .joystick(u, d, l, r, cn, rad, st):
            var k = [u, d, l, r]; k[slot] = b
            draft.controls[i] = .joystick(up: k[0], down: k[1], left: k[2], right: k[3], center: cn, radius: rad, stick: st)
            advanceDirection()
        case let .lookKeys(u, d, l, r, cn, rad, sp):
            var k = [u, d, l, r]; k[slot] = b
            draft.controls[i] = .lookKeys(up: k[0], down: k[1], left: k[2], right: k[3], center: cn, radius: rad, speed: sp)
            advanceDirection()
        case let .gravity(u, d, l, r):
            var k = [u, d, l, r]; k[slot] = b
            draft.controls[i] = .gravity(up: k[0], down: k[1], left: k[2], right: k[3])
            advanceDirection()
        }
    }

    /// Typing W, A, S, D in a row fills up → left → down → right.
    private func advanceDirection() {
        let order = [0, 2, 1, 3]
        if let k = order.firstIndex(of: slot), k + 1 < order.count { slot = order[k + 1] }
    }

    private func move(_ i: Int, to p: CGPoint, _ r: CGRect) {
        let n = norm(p, r)
        let a = ControlGeometry.describe(draft.controls[i], extra: draft.extra(i)).anchor
        let dx = n.x - a.x, dy = n.y - a.y
        let sh = { (q: NPoint) in NPoint(min(max(q.x + dx, 0), 1), min(max(q.y + dy, 0), 1)) }
        switch draft.controls[i] {
        case let .button(b, _, m): draft.controls[i] = .button(binding: b, at: n, mode: m)
        case let .joystick(u, d, l, rr, _, rad, s): draft.controls[i] = .joystick(up: u, down: d, left: l, right: rr, center: n, radius: rad, stick: s)
        case let .aim(_, rad, s, st): draft.controls[i] = .aim(center: n, radius: rad, sensitivity: s, stick: st)
        case let .lookKeys(u, d, l, rr, _, rad, sp): draft.controls[i] = .lookKeys(up: u, down: d, left: l, right: rr, center: n, radius: rad, speed: sp)
        case let .skill(b, _, rad, o): draft.controls[i] = .skill(binding: b, at: n, radius: rad, options: o)
        case let .swipe(b, path, ms): draft.controls[i] = .swipe(binding: b, path: path.map(sh), durationMs: ms)
        case let .fire(b, _, rad, d): draft.controls[i] = .fire(binding: b, at: n, radius: rad, dragAim: d)
        case let .spellCancel(b, _): draft.controls[i] = .spellCancel(binding: b, at: n)
        case let .rightWalk(b, _, rad): draft.controls[i] = .rightWalk(binding: b, center: n, radius: rad)
        case let .observe(b, _, rad, s): draft.controls[i] = .observe(binding: b, at: n, radius: rad, sensitivity: s)
        case let .zoomKeys(zi, zo, _): draft.controls[i] = .zoomKeys(zoomIn: zi, zoomOut: zo, center: n)
        case let .macro(b, press, release):
            let mv = { (acts: [MacroAction]) in acts.map { a -> MacroAction in
                switch a {
                case let .tap(q, h): return .tap(sh(q), holdMs: h)
                case let .down(q, f): return .down(sh(q), finger: f)
                case let .swipe(path, ms): return .swipe(path.map(sh), ms: ms)
                default: return a
                }
            } }
            draft.controls[i] = .macro(binding: b, press: mv(press), release: mv(release))
        case .gravity:
            var e = draft.extra(i); e.position = n; draft.setExtra(i, e)
        }
    }

    private func resize(_ i: Int, _ v: Double) {
        switch draft.controls[i] {
        case let .joystick(u, d, l, r, c, _, s): draft.controls[i] = .joystick(up: u, down: d, left: l, right: r, center: c, radius: v, stick: s)
        case let .aim(c, _, s, st): draft.controls[i] = .aim(center: c, radius: v, sensitivity: s, stick: st)
        case let .lookKeys(u, d, l, r, c, _, sp): draft.controls[i] = .lookKeys(up: u, down: d, left: l, right: r, center: c, radius: v, speed: sp)
        case let .skill(b, at, _, o): draft.controls[i] = .skill(binding: b, at: at, radius: v, options: o)
        case let .fire(b, at, _, d): draft.controls[i] = .fire(binding: b, at: at, radius: v, dragAim: d)
        case let .rightWalk(b, c, _): draft.controls[i] = .rightWalk(binding: b, center: c, radius: v)
        case let .observe(b, at, _, s): draft.controls[i] = .observe(binding: b, at: at, radius: v, sensitivity: s)
        default: break
        }
    }

    /// 连击按键 side handle: 调整点击次数.
    private func bump(_ i: Int, _ d: Int) {
        guard case let .button(b, at, mode) = draft.controls[i] else { return }
        switch mode {
        case let .turbo(hz): draft.controls[i] = .button(binding: b, at: at, mode: .turbo(hz: min(max(hz + Double(d), 1), 30)))
        case let .burst(n, hz): draft.controls[i] = .button(binding: b, at: at, mode: .burst(count: min(max(n + d, 1), 99), hz: hz))
        default: break
        }
    }

    private func delete(_ i: Int) {
        draft.removeControl(at: i)
        // 取消施法 belongs to skills: it goes when the last skill / fire key goes.
        let needsCancel = draft.controls.contains { if case .skill = $0 { return true }; if case .fire = $0 { return true }; return false }
        if !needsCancel {
            for j in draft.controls.indices.reversed() { if case .spellCancel = draft.controls[j] { draft.removeControl(at: j) } }
        }
        focused = nil
        settingsFor = nil
        hovered = nil
    }

    // MARK: Conflicts & saving

    private var conflicts: Set<KolibriCore.Binding> {
        var seen: [KolibriCore.Binding: Int] = [:]
        for c in draft.controls { for b in c.triggers where b != .pad("-") { seen[b, default: 0] += 1 } }
        if let t = draft.aimToggle { seen[t, default: 0] += 1 }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    private func save() {
        if !conflicts.isEmpty { dialog = .conflict; return }
        if draft.controls.isEmpty { dialog = .empty; return }
        session.saveScheme(draft, kind: kind, replacing: savedName)
        session.editing = nil
    }

    private func leave() {
        if draft != original { dialog = .leave } else { session.editing = nil }
    }

    // MARK: Pieces

    private var editBar: some View {
        HStack(spacing: 14) {
            Text(L("编辑方案：\(draft.name)")).font(.headline).lineLimit(1)
            Divider().frame(height: 16)
            Button(L("清空")) { dialog = .clear }
            Button(L("重置")) { dialog = .reset }
            Button(L("重命名")) { renameText = draft.name; dialog = .rename }
            Button(L("教程")) { showHelp = true }
            Button(L("保存")) { save() }.buttonStyle(.borderedProminent)
            Button { leave() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help(L("退出编辑"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func tip(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.65), in: Capsule())
            .allowsHitTesting(false)
    }

    private var alertTitle: String {
        switch dialog {
        case .clear: return L("确定清空吗？")
        case .reset: return L("确定重置吗？")
        case .rename: return L("输入方案名称：")
        case .leave: return L("离开而不保存？")
        case .empty: return L("方案未配置任何按键，无法继续保存，您是否要删除方案？")
        case .conflict: return L("存在按键冲突")
        case nil: return ""
        }
    }

    private var alertMessage: String {
        switch dialog {
        case .clear: return L("将清除所有您个人所做的修改。")
        case .reset: return L("方案将恢复至初始状态，同时将清除所有您个人所做的修改。")
        case .leave: return L("将会回到本次编辑前的方案。")
        case .conflict: return L("标红的按键使用了相同的键值，请修改后再保存。")
        default: return ""
        }
    }

    @ViewBuilder
    private var alertButtons: some View {
        switch dialog {
        case .clear:
            Button(L("清空"), role: .destructive) { draft.controls = []; draft.extras = []; focused = nil; settingsFor = nil }
            Button(L("取消"), role: .cancel) {}
        case .reset:
            Button(L("重置"), role: .destructive) { draft = original; focused = nil; settingsFor = nil }
            Button(L("取消"), role: .cancel) {}
        case .rename:
            TextField(L("方案名称"), text: $renameText)
            Button(L("确定")) {
                let n = renameText.trimmingCharacters(in: .whitespaces)
                if n.isEmpty { session.show(L("重命名的方案名称不能为空")) }
                else if n != savedName && session.schemes(kind).contains(n) { session.show(L("重命名的方案名称已被使用")) }
                else { draft.name = n }
            }
            Button(L("取消"), role: .cancel) {}
        case .leave:
            Button(L("离开"), role: .destructive) { session.editing = nil }
            Button(L("继续编辑"), role: .cancel) {}
        case .empty:
            Button(L("删除方案"), role: .destructive) {
                if let n = savedName { KeymapStore.delete(session.foregroundPackage, kind, n) }
                session.reloadSchemes()
                session.editing = nil
            }
            Button(L("继续编辑"), role: .cancel) {}
        case .conflict, nil:
            Button(L("好")) {}
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("键位编辑教程")).font(.title3.bold())
            Label(L("在画面空白处点击鼠标右键，选择要添加的按键"), systemImage: "cursorarrow.click.2")
            Label(L("点击菜单项直接放下，或按住拖到游戏操作按钮上"), systemImage: "hand.draw")
            Label(L("按键处于输入状态时，按下键盘或鼠标按键设置键值"), systemImage: "keyboard")
            Label(L("鼠标移到按键上：⚙ 打开设置，× 删除；拖动可移动位置"), systemImage: "gearshape")
            Label(L("选中按键后，拖动左侧的手柄调整大小或施法范围"), systemImage: "arrow.up.and.down")
            Label(L("滑动键位：选中后在画面上按住鼠标左键画出滑动轨迹"), systemImage: "scribble")
            Label(L("红色按键表示键值冲突，修改后才能保存"), systemImage: "exclamationmark.triangle")
            HStack { Spacer(); Button(L("知道了")) { showHelp = false }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 460)
    }

    // MARK: Settings panel (⚙)

    private func settingsPanel(_ i: Int) -> some View {
        let c = draft.controls[i]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ControlKind.of(c).settingsTitle).font(.headline)
                Spacer()
                Button { settingsFor = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            fields(i, c)
            Divider()
            HStack {
                Text(L("备注"))
                TextField(L("建议5字以内"), text: SwiftUI.Binding(
                    get: { draft.extra(i).note },
                    set: { var e = draft.extra(i); e.note = String($0.prefix(8)); draft.setExtra(i, e) }))
                    .textFieldStyle(.roundedBorder)
            }
            Toggle(L("开启此提示"), isOn: SwiftUI.Binding(
                get: { draft.extra(i).showHint },
                set: { var e = draft.extra(i); e.showHint = $0; draft.setExtra(i, e) }))
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
    }

    @ViewBuilder
    private func fields(_ i: Int, _ c: Control) -> some View {
        switch c {
        case let .button(b, at, mode):
            if ControlKind.of(c) == .burstTap {
                segmented(L("操作方式"), [L("长按连击"), L("按键后连击")], { if case .burst = mode { return 1 }; return 0 }()) { v in
                    draft.controls[i] = .button(binding: b, at: at, mode: v == 0 ? .turbo(hz: 10) : .burst(count: 10, hz: 10))
                }
                if case let .turbo(hz) = mode {
                    number(L("每秒连击次数"), Int(hz), 1...30) { draft.controls[i] = .button(binding: b, at: at, mode: .turbo(hz: Double($0))) }
                }
                if case let .burst(n, hz) = mode {
                    number(L("连击次数"), n, 1...99) { draft.controls[i] = .button(binding: b, at: at, mode: .burst(count: $0, hz: hz)) }
                    number(L("每秒连击次数"), Int(hz), 1...30) { draft.controls[i] = .button(binding: b, at: at, mode: .burst(count: n, hz: Double($0))) }
                }
            } else {
                // every click key can pick how a press becomes taps.
                let modes: [TriggerMode] = [.hold, .click(holdMs: 40), .doubleClick(holdMs: 40, gapMs: 60), .toggle, .longPress(ms: 600)]
                Picker(L("触发方式"), selection: SwiftUI.Binding(get: { mode.kind }, set: { kk in
                    if let m = modes.first(where: { $0.kind == kk }) { draft.controls[i] = .button(binding: b, at: at, mode: m) }
                })) { ForEach(modes, id: \.kind) { Text($0.title).tag($0.kind) } }
                if case let .longPress(ms) = mode {
                    number(L("长按时长(ms)"), ms, 100...5000, step: 100) { draft.controls[i] = .button(binding: b, at: at, mode: .longPress(ms: $0)) }
                }
            }
        case let .skill(b, at, r, o):
            segmented(L("施法时机"), [L("松开释放"), L("立即释放")], o.castOnRelease ? 0 : 1) { v in
                var o = o; o.castOnRelease = v == 0; draft.controls[i] = .skill(binding: b, at: at, radius: r, options: o)
            }
            Toggle(L("行走跟随施法方向"), isOn: SwiftUI.Binding(get: { o.followJoystick }, set: { v in
                var o = o; o.followJoystick = v; draft.controls[i] = .skill(binding: b, at: at, radius: r, options: o)
            }))
            cancelToggle(near: at)
        case let .fire(b, at, r, d):
            Toggle(L("拖拽施法"), isOn: SwiftUI.Binding(get: { d }, set: { draft.controls[i] = .fire(binding: b, at: at, radius: r, dragAim: $0) }))
            cancelToggle(near: at)
        case let .aim(cn, r, s, st):
            slider(L("灵敏度"), s, 0.2...4) { draft.controls[i] = .aim(center: cn, radius: r, sensitivity: $0, stick: st) }
            Text(L("按准心键锁定鼠标，再按一次解锁")).font(.caption).foregroundStyle(.secondary)
        case let .lookKeys(u, d, l, rr, cn, rad, sp):
            slider(L("滑动速度"), sp, 0.1...2) { draft.controls[i] = .lookKeys(up: u, down: d, left: l, right: rr, center: cn, radius: rad, speed: $0) }
        case let .observe(b, at, r, s):
            slider(L("滑动速度"), s, 0.2...4) { draft.controls[i] = .observe(binding: b, at: at, radius: r, sensitivity: $0) }
        case let .swipe(b, path, ms):
            if ControlKind.of(c) == .wheel {
                number(L("操作时间（ms）"), ms, 50...3000, step: 50) { draft.controls[i] = .swipe(binding: b, path: path, durationMs: $0) }
            } else {
                Toggle(L("直线轨迹"), isOn: SwiftUI.Binding(get: { draft.extra(i).straightLine }, set: { v in
                    var e = draft.extra(i); e.straightLine = v; draft.setExtra(i, e)
                    if v, path.count > 2 { draft.controls[i] = .swipe(binding: b, path: [path.first!, path.last!], durationMs: ms) }
                }))
                number(L("滑动时长(ms)"), ms, 50...3000, step: 50) { draft.controls[i] = .swipe(binding: b, path: path, durationMs: $0) }
                Text(L("选中后在画面上按住鼠标左键画出轨迹")).font(.caption).foregroundStyle(.secondary)
            }
        case .macro:
            Button(L("编辑宏脚本…")) { editMacro(i) }
        default:
            EmptyView()
        }
    }

    /// 取消施法 switch: places one cancel key for the scheme.
    private func cancelToggle(near at: NPoint) -> some View {
        let has = draft.controls.contains { if case .spellCancel = $0 { return true }; return false }
        return Toggle(L("取消施法"), isOn: SwiftUI.Binding(get: { has }, set: { on in
            if on, !has {
                draft.controls.append(.spellCancel(binding: .key(48), at: NPoint(min(at.x + 0.08, 0.97), max(at.y - 0.2, 0.05))))
            } else if !on {
                for j in draft.controls.indices.reversed() { if case .spellCancel = draft.controls[j] { draft.removeControl(at: j) } }
            }
        }))
    }

    private func editMacro(_ i: Int) {
        guard case let .macro(b, press, release) = draft.controls[i] else { return }
        let host = NSHostingController(rootView: MacroScriptSheet(press: press, release: release) { p, r in
            draft.controls[i] = .macro(binding: b, press: p, release: r)
        })
        NSApp.keyWindow?.contentViewController?.presentAsSheet(host)
    }

    private func segmented(_ title: String, _ items: [String], _ sel: Int, _ set: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker("", selection: SwiftUI.Binding(get: { sel }, set: set)) {
                ForEach(items.indices, id: \.self) { Text(items[$0]).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    private func number(_ title: String, _ v: Int, _ range: ClosedRange<Int>, step: Int = 1, _ set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { set(max(range.lowerBound, v - step)) } label: { Image(systemName: "minus") }
            Text("\(v)").monospacedDigit().frame(minWidth: 36)
            Button { set(min(range.upperBound, v + step)) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
    }

    private func slider(_ title: String, _ v: Double, _ range: ClosedRange<Double>, _ set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Slider(value: SwiftUI.Binding(get: { v }, set: set), in: range)
            Text(String(format: "%.1f", v)).monospacedDigit().frame(width: 30)
        }
    }

    // MARK: Geometry

    private func fitRect(_ size: CGSize) -> CGRect {
        GuestRect.fit(size, width: session.instance.width, height: session.instance.height)
    }

    private func norm(_ p: CGPoint, _ r: CGRect) -> NPoint {
        NPoint(min(max((p.x - r.minX) / r.width, 0), 1), min(max((p.y - r.minY) / r.height, 0), 1))
    }

    private func menuPosition(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let m = AddMenu.size(for: kind)
        return CGPoint(x: min(max(p.x + m.width / 2, m.width / 2 + 8), size.width - m.width / 2 - 8),
                       y: min(max(p.y + m.height / 2, m.height / 2 + 8), size.height - m.height / 2 - 8))
    }

    private func panelPosition(_ i: Int, _ r: CGRect, _ size: CGSize) -> CGPoint {
        let a = ControlGeometry.describe(draft.controls[i], extra: draft.extra(i)).anchor
        let x = r.minX + a.x * r.width, y = r.minY + a.y * r.height
        let px = x + 190 < size.width - 10 ? x + 190 : x - 190
        return CGPoint(x: px, y: min(max(y, 170), size.height - 170))
    }
}

/// Where the guest picture sits inside a view (aspect-fit, same as the renderer).
enum GuestRect {
    static func fit(_ size: CGSize, width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        let s = min(size.width / w, size.height / h)
        return CGRect(x: (size.width - w * s) / 2, y: (size.height - h * s) / 2, width: w * s, height: h * s)
    }
}

// MARK: - Add menu (右键菜单)

private struct AddMenu: View {
    let kind: SchemeKind
    let isTaken: (ControlKind) -> Bool
    let onClick: (ControlKind) -> Void
    let onDrag: (ControlKind, CGPoint) -> Void
    let onDragEnd: () -> Void
    @State private var hover: ControlKind?

    static func size(for kind: SchemeKind) -> CGSize {
        let rows = (ControlKind.palette(kind).count + 2) / 3
        return CGSize(width: 300, height: CGFloat(rows) * 70 + 76)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == .keyboard ? L("添加键鼠按键") : L("添加手柄按键")).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(ControlKind.palette(kind)) { k in
                    let taken = isTaken(k)
                    VStack(spacing: 6) {
                        Image(systemName: k.symbol).font(.system(size: 20)).frame(height: 24)
                        Text(k.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(hover == k && !taken ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8))
                    .opacity(taken ? 0.35 : 1)
                    .contentShape(Rectangle())
                    .onHover { hover = $0 ? k : (hover == k ? nil : hover) }
                    .onTapGesture { if !taken { onClick(k) } }
                    .gesture(DragGesture(minimumDistance: 20, coordinateSpace: .named("canvas"))
                        .onChanged { v in if !taken { onDrag(k, v.location) } }
                        .onEnded { _ in onDragEnd() })
                }
            }
            Text(hover.map { isTaken($0) ? L("该按键只能添加一个") : L("点击或拖动到游戏操作按钮上") } ?? L("点击或拖动到游戏操作按钮上"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: Self.size(for: kind).width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 14)
    }
}

// MARK: - A key on the canvas

private struct KeyCap: View {
    enum Look { case normal, hover, focused }

    let control: Control
    let extra: ControlExtra
    let rect: CGRect
    let aimToggle: KolibriCore.Binding?
    let state: Look
    let listeningSlot: Int?
    let conflicts: Set<KolibriCore.Binding>
    let onFocus: (Int) -> Void
    let onHover: (Bool) -> Void
    let onMove: (CGPoint) -> Void
    let onSettings: () -> Void
    let onDelete: () -> Void
    let onResize: (Double) -> Void
    let onCount: (Int) -> Void
    @State private var blink = true

    private var kind: ControlKind { ControlKind.of(control) }
    private var shape: ControlGeometry.Shape { ControlGeometry.describe(control, extra: extra) }
    private var center: CGPoint { point(shape.anchor) }
    private func point(_ n: NPoint) -> CGPoint { CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height) }
    private var ringPx: CGFloat { CGFloat(shape.radius) * rect.width }
    private var active: Bool { state != .normal }

    var body: some View {
        ZStack {
            if case let .swipe(_, path, _) = control, path.count > 1 {
                Path { p in p.addLines(path.map(point)) }
                    .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 6]))
                    .allowsHitTesting(false)
                Image(systemName: "arrowtriangle.right.fill").foregroundStyle(.white)
                    .rotationEffect(angle(path[path.count - 2], path.last!)).position(point(path.last!)).allowsHitTesting(false)
            }
            // Range rings: sticks always show theirs; 准心/观察/施法 ranges only while selected.
            if ringPx > 0, active || [.dpad, .eye, .rightWalk, .leftStick].contains(kind) {
                let dashed = ![.dpad, .eye, .rightWalk, .leftStick].contains(kind)
                Circle().stroke(active ? Color.yellow : Color.white.opacity(0.7),
                                style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 5] : []))
                    .background(Circle().fill(Color.black.opacity(dashed ? 0.08 : 0.25)))
                    .frame(width: ringPx * 2, height: ringPx * 2)
                    .position(center)
                    .allowsHitTesting(false)
            }
            cap.position(center)
            if active { decorations }
        }
    }

    @ViewBuilder
    private var cap: some View {
        Group {
            if let dirs = shape.directions, ringPx > 0 || kind == .gravity {
                // 方向键 / 视角移动 / 重力感应: four key slots around the center.
                let r = max(ringPx, 34)
                ZStack {
                    Image(systemName: kind.symbol).font(.system(size: 18)).foregroundStyle(.white.opacity(0.85))
                    ForEach(0..<4, id: \.self) { s in
                        let off: CGSize = [CGSize(width: 0, height: -r), CGSize(width: 0, height: r),
                                           CGSize(width: -r, height: 0), CGSize(width: r, height: 0)][s]
                        keyLabel(dirs[s], slot: s, binding: slotBinding(s)).offset(off)
                    }
                }
                .frame(width: r * 2 + 44, height: r * 2 + 44)
            } else if case let .zoomKeys(zi, zo, _) = control {
                HStack(spacing: 4) {
                    keyLabel(KeyNames.name(zi), slot: 0, binding: zi)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.white)
                    keyLabel(KeyNames.name(zo), slot: 1, binding: zo)
                }
                .padding(6).background(Color.black.opacity(0.6), in: Capsule())
            } else if case .aim = control {
                VStack(spacing: 2) {
                    Image(systemName: "scope").font(.system(size: 18)).foregroundStyle(.white)
                    keyLabel(aimToggle.map(KeyNames.name) ?? "", slot: 0, binding: aimToggle)
                }
            } else {
                keyLabel(shape.label, slot: 0, binding: control.triggers.first)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas")).onChanged { onMove($0.location) })
    }

    private func slotBinding(_ s: Int) -> KolibriCore.Binding? {
        let t = control.triggers
        return t.indices.contains(s) ? t[s] : nil
    }

    /// One key box: dark rounded cap, red on conflict, blinking underline while listening.
    private func keyLabel(_ text: String, slot s: Int, binding: KolibriCore.Binding?) -> some View {
        let listening = listeningSlot == s
        let conflict = binding.map(conflicts.contains) ?? false
        return ZStack(alignment: .bottom) {
            Text(text.isEmpty && !listening ? "?" : text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 40, minHeight: 40)
                .padding(.horizontal, 4)
                .background(conflict ? Color.red.opacity(0.85) : Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(listening ? Color.yellow : (active ? Color.white : Color.white.opacity(0.5)), lineWidth: listening ? 2 : 1))
            if listening {
                Rectangle().fill(Color.white).frame(width: 22, height: 2).padding(.bottom, 6).opacity(blink ? 1 : 0)
                    .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { blink.toggle() } }
            }
        }
        .onTapGesture { onFocus(s) }
    }

    /// ⚙ / × on hover or focus, plus the size handle beside a focused key.
    @ViewBuilder
    private var decorations: some View {
        let half = max(ringPx, kind == .gravity || shape.directions != nil ? 56 : 24) + 6
        circleButton("gearshape.fill", action: onSettings).position(x: center.x - half, y: center.y - half)
        circleButton("xmark", action: onDelete).position(x: center.x + half, y: center.y - half)
        if state == .focused, let tip = kind.sizeTip {
            SizeHandle(value: shape.radius, tip: tip, onChange: onResize)
                .position(x: center.x - half - 18, y: center.y + 12)
        } else if state == .focused, kind == .burstTap {
            VStack(spacing: 4) {
                circleButton("plus") { onCount(1) }
                circleButton("minus") { onCount(-1) }
            }
            .help(L("调整点击次数"))
            .position(x: center.x - half - 14, y: center.y)
        }
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Color.black.opacity(0.8), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func angle(_ a: NPoint, _ b: NPoint) -> Angle {
        .radians(atan2((b.y - a.y) * rect.height, (b.x - a.x) * rect.width))
    }
}

/// Vertical handle beside a focused key: drag up to grow, down to shrink.
private struct SizeHandle: View {
    let value: Double
    let tip: String
    let onChange: (Double) -> Void
    @State private var start: Double?

    var body: some View {
        Capsule().fill(Color.black.opacity(0.75))
            .overlay(VStack { Image(systemName: "chevron.up"); Spacer(); Image(systemName: "chevron.down") }
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(.vertical, 6))
            .overlay(Capsule().stroke(Color.white.opacity(0.6)))
            .frame(width: 18, height: 64)
            .help(tip)
            .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                if start == nil { start = value }
                onChange(min(max(start! - Double(v.translation.height) / 600, 0.02), 0.35))
            }.onEnded { _ in start = nil })
    }
}

// MARK: - Mouse on the empty canvas (right-click menu, swipe drawing)

private struct CanvasMouse: NSViewRepresentable {
    let onLeftDown: (CGPoint) -> Void
    let onLeftDrag: (CGPoint) -> Void
    let onLeftUp: () -> Void
    let onRightDown: (CGPoint) -> Void

    final class View: NSView {
        var parent: CanvasMouse?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private func p(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
        override func mouseDown(with e: NSEvent) { parent?.onLeftDown(p(e)) }
        override func mouseDragged(with e: NSEvent) { parent?.onLeftDrag(p(e)) }
        override func mouseUp(with e: NSEvent) { parent?.onLeftUp() }
        override func rightMouseDown(with e: NSEvent) { parent?.onRightDown(p(e)) }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }

    func makeNSView(context: Context) -> View { let v = View(); v.parent = self; return v }
    func updateNSView(_ v: View, context: Context) { v.parent = self }
}
