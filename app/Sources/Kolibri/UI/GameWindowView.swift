import SwiftUI
import UniformTypeIdentifiers
import KolibriCore

/// Game window: Metal display, native title-bar toolbar (customizable), key hints, editor, recorder bar and toasts.
struct GameWindowView: View {
    let instanceName: String
    @State private var session: GameSession?
    @State private var error: String?

    var body: some View {
        Group {
            if let session {
                GameScreen(session: session)
            } else if let error {
                ContentUnavailableView(L("无法连接实例"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView(L("连接 \(instanceName)…"))
            }
        }
        .background(.black)
        .navigationTitle(instanceName)
        .task {
            do {
                guard let inst = try await KolibriCtl.list().first(where: { $0.name == instanceName }), inst.running else {
                    error = L("实例未运行")
                    return
                }
                session = try GameSession(instance: inst)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onDisappear { session?.shutdown() }
    }
}

private struct GameScreen: View {
    @ObservedObject var session: GameSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            GameDisplay(session: session)
            if session.keymapEnabled && session.hintsVisible && session.editing == nil {
                KeymapHints(keymap: session.keymap, width: session.instance.width, height: session.instance.height).allowsHitTesting(false)
            }
            if !session.touchMarks.isEmpty { TouchMarks(marks: session.touchMarks).allowsHitTesting(false) }
            if let kind = session.editing {
                KeymapEditor(session: session, kind: kind).id(kind)
            }
            VStack(alignment: .leading, spacing: 6) {
                if session.showFPS { fpsBadge }
                if session.pointerLocked {
                    Text(L("鼠标已锁定（视角模式）· 按 \(session.keymap.aimToggle.map(KeyNames.name) ?? "`") 解锁")).font(.caption).padding(6)
                        .background(.black.opacity(0.6), in: Capsule())
                }
                if !session.status.isEmpty {
                    Text(session.status).font(.caption).padding(6).background(.black.opacity(0.6), in: Capsule())
                }
            }
            .padding(10)
            .allowsHitTesting(false)
            VStack(spacing: 8) {
                if session.screenRecording { RecordingBadge(session: session) }
                if session.opState != .idle { OperationBar(session: session) }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, 10)
            if let toast = session.toast {
                Text(toast).padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .overlay { if let kind = session.dropKind { DropOverlay(kind: kind) } }
        .animation(.easeOut(duration: 0.15), value: session.dropKind)
        .toolbar(id: "game") { GameToolbar(session: session) }
        .toolbarRole(.editor)
        .sheet(isPresented: $session.showRecordings) { RecordingsView(session: session) }
        .sheet(isPresented: $session.showManage) { KeymapManageView(session: session, kind: .keyboard) }
        .focusedSceneObject(session)
    }

    private var fpsBadge: some View {
        HStack(spacing: 8) {
            Text("FPS \(Int(session.guestFPS.rounded()))").bold()
            Text(L("显示 \(Int(session.displayFPS.rounded()))Hz")).foregroundStyle(.secondary)
            if let pkg = session.foregroundPackage { Text(pkg).foregroundStyle(.secondary) }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.6), in: Capsule())
    }

}

/// Shown while files are dragged over the game (the drop itself lands in GameDisplayView).
private struct DropOverlay: View {
    let kind: GameSession.DropKind

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 44, weight: .light))
                Text(title).font(.title3.weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 36).padding(.vertical, 28)
            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        }
        .allowsHitTesting(false)
    }

    private var symbol: String {
        switch kind {
        case .install: "shippingbox"
        case .transfer: "tray.and.arrow.down"
        case .mixed: "square.and.arrow.down.on.square"
        }
    }

    private var title: String {
        switch kind {
        case .install(let n): n > 1 ? L("松开鼠标，安装 \(n) 个应用") : L("松开鼠标开始安装")
        case .transfer(let n): n > 1 ? L("松开鼠标，\(n) 个文件传到安卓「下载」") : L("松开鼠标，传到安卓「下载」")
        case .mixed(let n): L("松开鼠标，安装应用并传输文件（共 \(n) 个）")
        }
    }
}

// MARK: Toolbar

/// Title-bar toolbar with items, labels and tooltips (返回 · 主页 ·
/// 旋转屏幕 · 摇一摇 · 调整音量 · 安装APK · 打开共享文件夹 · 打开ADB · 使用键鼠 ·
/// 使用手柄 · 操作录制), plus our 截图 and 录屏. 自定义工具栏… rearranges them.
struct GameToolbar: CustomizableToolbarContent {
    @ObservedObject var session: GameSession
    @State private var keymapPopover = false
    @State private var gamepadPopover = false
    @State private var volumePopover = false

    var body: some CustomizableToolbarContent {
        Group {
            item("back", L("返回"), "arrow.uturn.backward", tip: L("返回上一级")) { session.sendAndroidKey("GoBack") }
            item("home", L("主页"), "house", tip: L("返回主页")) { session.sendAndroidKey("GoHome") }
            item("rotation", L("旋转屏幕"), "rotate.right", tip: L("旋转屏幕")) { Task { await session.rotate() } }
            item("shake", L("摇一摇"), "iphone.radiowaves.left.and.right", tip: L("模拟设备晃动")) { session.shake() }
            ToolbarItem(id: "volume", placement: .primaryAction) {
                Button { volumePopover.toggle() } label: { Label(L("调整音量"), systemImage: "speaker.wave.2") }
                    .help(L("调整音量"))
                    .popover(isPresented: $volumePopover, arrowEdge: .bottom) { VolumePopover(session: session) }
            }
            item("installApk", L("安装APK"), "shippingbox", tip: L("安装APK")) {
                if let urls = pickPackages() { session.handleDrop(urls) }
            }
            item("sharedFolder", L("打开共享文件夹"), "folder", tip: L("打开电脑共享文件夹")) { Task { await session.syncSharedFolder() } }
            item("openADB", L("打开ADB"), "terminal", tip: L("打开ADB")) { session.openADB() }
        }
        Group {
            ToolbarItem(id: "keymap", placement: .primaryAction) {
                Button { keymapPopover.toggle() } label: {
                    Label(L("使用键鼠"), systemImage: session.isDisabled(.keyboard) ? "keyboard" : "keyboard.fill")
                }
                .help(L("打开键鼠设置"))
                .popover(isPresented: $keymapPopover, arrowEdge: .bottom) {
                    KeymapPopover(session: session, kind: .keyboard) { keymapPopover = false }
                }
            }
            ToolbarItem(id: "joystick", placement: .primaryAction) {
                Button { gamepadPopover.toggle() } label: {
                    Label(L("使用手柄"), systemImage: session.padConnected ? "gamecontroller.fill" : "gamecontroller")
                }
                .help(L("打开手柄设置"))
                .popover(isPresented: $gamepadPopover, arrowEdge: .bottom) {
                    KeymapPopover(session: session, kind: .gamepad) { gamepadPopover = false }
                }
            }
            item("operationRecorder", L("操作录制"), session.opState == .idle ? "record.circle" : "record.circle.fill", tip: L("操作录制")) {
                session.showRecordings = true
            }
            item("screenshot", L("截图"), "camera", tip: L("截图  ⌃⌘A")) { session.screenshot() }
            item("screenRecord", L("录屏"), session.screenRecording ? "stop.circle.fill" : "video", tip: L("录屏  ⌃⌘R")) {
                session.toggleScreenRecording()
            }
        }
    }

    private func item(_ id: String, _ label: String, _ symbol: String, tip: String,
                      _ action: @escaping () -> Void) -> some CustomizableToolbarContent {
        ToolbarItem(id: id, placement: .primaryAction) {
            Button(action: action) { Label(label, systemImage: symbol) }
                .help(tip)
                .disabled(session.editing != nil)
        }
    }

    private func pick(_ types: [UTType], _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }
}

/// 安装APK: .apk and split-APK bundles, several at once.
func pickPackages() -> [URL]? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = ["apk", "xapk", "apks", "apkm"].compactMap { UTType(filenameExtension: $0) }
    return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
}

/// 调整音量: step buttons (the guest has no absolute volume over gRPC).
private struct VolumePopover: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 14) {
            Button { session.sendAndroidKey("AudioVolumeMute") } label: { Image(systemName: "speaker.slash") }.help(L("静音"))
            Button { session.sendAndroidKey("AudioVolumeDown") } label: { Image(systemName: "speaker.wave.1") }.help(L("音量 −"))
            Button { session.sendAndroidKey("AudioVolumeUp") } label: { Image(systemName: "speaker.wave.3") }.help(L("音量 +"))
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .padding(14)
    }
}

// MARK: Menu bar (工具 / 键位, work on the focused game window)

struct GameCommands: Commands {
    @FocusedObject private var session: GameSession?
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue   // menus follow the language

    var body: some Commands {
        CommandMenu(L("工具")) {
            Group {
                Button(L("返回")) { session?.sendAndroidKey("GoBack") }
                Button(L("主页")) { session?.sendAndroidKey("GoHome") }
                Divider()
                Button(L("旋转屏幕")) { Task { await session?.rotate() } }
                Button(L("摇一摇")) { session?.shake() }
                Button(L("增大音量")) { session?.sendAndroidKey("AudioVolumeUp") }
                Button(L("减小音量")) { session?.sendAndroidKey("AudioVolumeDown") }
                Button(L("静音")) { session?.sendAndroidKey("AudioVolumeMute") }
                Divider()
                Button(L("安装APK…")) {
                    if let urls = pickPackages() { session?.handleDrop(urls) }
                }
                Button(L("打开共享文件夹")) { Task { await session?.syncSharedFolder() } }
                Button(L("打开ADB")) { session?.openADB() }
                Button(L("把 Mac 剪贴板发到安卓")) { session?.pasteToAndroid() }.keyboardShortcut("v", modifiers: [.control, .command])
            }
            .disabled(session == nil)
            Divider()
            Group {
                Button(L("截图")) { session?.screenshot() }.keyboardShortcut("a", modifiers: [.control, .command])
                Button(session?.screenRecording == true ? L("停止录屏") : L("开始录屏")) { session?.toggleScreenRecording() }
                    .keyboardShortcut("r", modifiers: [.control, .command])
                Button(session?.opState == .recording ? L("停止操作录制") : L("开始操作录制")) {
                    guard let s = session else { return }
                    s.opState == .idle ? s.startOperationRecording() : s.stopOperation()
                }
                .keyboardShortcut("o", modifiers: [.control, .command])
                Button(L("操作录制…")) { session?.showRecordings = true }
            }
            .disabled(session == nil)
        }
        CommandMenu(L("键位")) {
            Group {
                Menu(L("按键方案列表")) {
                    if let s = session {
                        Button((s.isDisabled(.keyboard) ? "✓ " : "") + L("不使用方案")) { s.disableScheme(.keyboard) }
                        ForEach(s.schemes(.keyboard), id: \.self) { n in
                            Button((!s.isDisabled(.keyboard) && s.keyboardScheme.name == n ? "✓ " : "") + n) { s.selectScheme(.keyboard, n) }
                        }
                    }
                }
                Button(L("新建按键方案")) { session?.beginEditing(.keyboard, newScheme: true) }
                Button(L("编辑按键方案")) { session?.beginEditing(.keyboard, newScheme: false) }
                    .disabled(session?.isDisabled(.keyboard) ?? true)
                Button(L("复制当前方案")) { session?.duplicateCurrent(.keyboard) }
                Button(L("删除当前方案")) { session?.deleteCurrent(.keyboard) }
                Divider()
                Button(L("导入按键方案…")) { session?.importScheme() }
                Button(L("导出按键方案…")) { session?.exportCurrent(.keyboard) }
                Divider()
                Button(session?.hintsVisible == false ? L("显示按键提示") : L("隐藏按键提示")) { session?.hintsVisible.toggle() }
                    .keyboardShortcut("k", modifiers: [.control, .command])
                Button(L("切换上个方案")) { session?.cycleScheme(.keyboard, by: -1) }.keyboardShortcut("[", modifiers: [.control, .command])
                Button(L("切换下个方案")) { session?.cycleScheme(.keyboard, by: 1) }.keyboardShortcut("]", modifiers: [.control, .command])
                Divider()
                Button(L("进入方案管理…")) { session?.showManage = true }
            }
            .disabled(session == nil || session?.editing != nil)
        }
    }
}

// MARK: Overlays

/// Recorder floating bar: timer, pause/resume, stop.
private struct OperationBar: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(session.opState == .recording ? .red : .green).frame(width: 9, height: 9)
                .opacity(session.opPaused ? 0.3 : 1)
            switch session.opState {
            case .recording: Text(L("录制中"))
            case let .playing(name):
                Text(L("执行「\(name)」"))
                if let (r, total) = session.operationRound { Text(total == 0 ? L("第 \(r) 次 / 循环") : L("第 \(r)/\(total) 次")).foregroundStyle(.secondary) }
            case .idle: EmptyView()
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                Text(clock(session.operationElapsed(CACurrentMediaTime()))).monospacedDigit()
            }
            Button { session.togglePauseOperation() } label: { Image(systemName: session.opPaused ? "play.fill" : "pause.fill") }
                .help(session.opPaused ? L("继续") : L("暂停"))
            Button { session.stopOperation() } label: { Image(systemName: "stop.fill") }.help(L("终止"))
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct RecordingBadge: View {
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 9, height: 9)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(L("录屏 \(clock(session.screenRecordingElapsed()))")).monospacedDigit()
            }
            Button(L("停止")) { session.toggleScreenRecording() }.buttonStyle(.plain).bold()
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

func clock(_ s: Double) -> String {
    let t = max(Int(s), 0)
    return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
}

private struct TouchMarks: View {
    let marks: [Int32: CGPoint]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(marks.keys), id: \.self) { id in
                if let p = marks[id] {
                    Circle().fill(.white.opacity(0.35)).overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 26, height: 26)
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                }
            }
        }
    }
}

/// In-game key hints: dark translucent key caps where the game's
/// buttons are, 4-key sticks drawn as a ring with their keys. 备注 replaces the key
/// text; controls with 开启此提示 off are not drawn.
struct KeymapHints: View {
    let keymap: Keymap
    let width: Int
    let height: Int

    var body: some View {
        GeometryReader { geo in
            let r = GuestRect.fit(geo.size, width: width, height: height)
            ForEach(Array(keymap.controls.enumerated()), id: \.offset) { i, c in
                let e = keymap.extra(i)
                if e.showHint {
                    hint(ControlGeometry.describe(c, extra: e), r)
                }
            }
        }
        .opacity(keymap.hintOpacity)
    }

    @ViewBuilder
    private func hint(_ d: ControlGeometry.Shape, _ r: CGRect) -> some View {
        let p = CGPoint(x: r.minX + d.anchor.x * r.width, y: r.minY + d.anchor.y * r.height)
        let ring = CGFloat(d.radius) * r.width
        if let dirs = d.directions {
            let rr = max(ring, 30)
            ZStack {
                if ring > 0 { Circle().stroke(.white.opacity(0.35), lineWidth: 1.5).frame(width: ring * 2, height: ring * 2) }
                ForEach(0..<4, id: \.self) { s in
                    let off: CGSize = [CGSize(width: 0, height: -rr), CGSize(width: 0, height: rr),
                                       CGSize(width: -rr, height: 0), CGSize(width: rr, height: 0)][s]
                    if !dirs[s].isEmpty { cap(dirs[s]).offset(off) }
                }
            }
            .position(p)
        } else if !d.label.isEmpty {
            // Ranges (准心 / 技能 / 观察) are an editing aid; in play only the key shows.
            cap(d.label).position(p)
        }
    }

    private func cap(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(minWidth: 28, minHeight: 28).padding(.horizontal, 3)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.5), lineWidth: 1))
    }
}
