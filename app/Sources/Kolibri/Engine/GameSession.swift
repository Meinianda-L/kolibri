import AppKit
import Combine
import Metal
import UniformTypeIdentifiers
import KolibriCore

/// Everything one running instance window needs: engine connection, zero-copy
/// frame buffer, keymap engine and schemes, gamepad, recorders and live stats.
@MainActor
final class GameSession: ObservableObject {
    let instance: InstanceInfo
    let client: EmulatorClient
    let renderer: GameRenderer
    let keymaps: KeymapEngine
    private let gamepad = GamepadInput()

    @Published var keymapEnabled = true
    @Published var pointerLocked = false
    @Published var showFPS = true
    /// ⌃⌘K: key hints over the game.
    @Published var hintsVisible = true
    @Published var editing: SchemeKind?
    @Published var showRecordings = false
    /// 进入方案管理.
    @Published var showManage = false
    @Published private(set) var keyboardScheme: Keymap
    @Published private(set) var gamepadScheme: Keymap
    /// Both active schemes merged: what the engine runs and the hints show.
    @Published private(set) var keymap: Keymap
    @Published private(set) var foregroundPackage: String?
    @Published private(set) var guestFPS: Double = 0
    @Published private(set) var displayFPS: Double = 0
    @Published private(set) var padConnected = false
    @Published var status: String = L("连接引擎中…")
    @Published var toast: String?
    /// What dropping the files being dragged over the window would do (overlay); nil otherwise.
    @Published var dropKind: DropKind?

    enum DropKind: Equatable {
        case install(Int), transfer(Int), mixed(Int)

        init?(_ urls: [URL]) {
            guard !urls.isEmpty else { return nil }
            let apps = urls.filter { GameSession.isPackage($0) }.count
            self = apps == urls.count ? .install(apps) : apps == 0 ? .transfer(urls.count) : .mixed(urls.count)
        }
    }
    /// While the editor waits for a gamepad button to bind.
    var padListener: ((Binding) -> Void)?

    // Operation recorder (操作录制)
    enum OpState: Equatable { case idle, recording, playing(String) }
    @Published private(set) var opState: OpState = .idle
    @Published private(set) var opPaused = false
    /// Normalized finger positions shown while recording/replaying.
    @Published private(set) var touchMarks: [Int32: CGPoint] = [:]
    private var opRecorder: OperationRecorder?
    private var opPlayer: OperationPlayer?

    // Screen recording (录屏)
    @Published private(set) var screenRecording = false
    private var screenRecorder: ScreenRecorder?
    /// (video frames, audio packets) of the last screen recording.
    private(set) var lastRecordingStats = (0, 0)
    private var audioStream: EngineAudioStream?

    private var frameTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var frameCount = 0
    private var drawCount = 0
    private var statsStart = CACurrentMediaTime()
    private var lastStickTick = CACurrentMediaTime()
    private nonisolated(unsafe) var latestSeq: UInt32 = 0

    init(instance: InstanceInfo) throws {
        self.instance = instance
        client = try EmulatorClient(port: instance.grpc_port)
        guard let device = MTLCreateSystemDefaultDevice() else { throw KolibriCtl.Failure(message: "no Metal device") }
        renderer = try GameRenderer(device: device, pixelFormat: .bgra8Unorm)
        let kb = KeymapStore.active(nil, .keyboard), pad = KeymapStore.active(nil, .gamepad)
        keyboardScheme = kb
        gamepadScheme = pad
        let k = KeymapStore.combined(keyboard: kb, gamepad: pad)
        keymap = k
        keymaps = KeymapEngine(keymap: k, screenWidth: instance.width, screenHeight: instance.height)

        keymaps.onKey = { [weak self] code, down in
            MainActor.assumeIsolated { self?.sendKey(code, down: down) }
        }
        let tiltClient = client
        keymaps.onTilt = { x, y in
            Task { await tiltClient.setTilt(pitch: Float(y * 35), roll: Float(x * 35)) }
        }
        renderer.onTick = { [weak self] now in
            MainActor.assumeIsolated { self?.tick(now) }
        }
        gamepad.onButton = { [weak self] b, down in
            MainActor.assumeIsolated {
                if down, let l = self?.padListener { l(b); return }
                self?.handle(binding: b, down: down)
            }
        }
        gamepad.onStick = { [weak self] name, x, y in
            MainActor.assumeIsolated { self?.stick(name, x, y) }
        }
        gamepad.onConnection = { [weak self] name, connected in
            MainActor.assumeIsolated {
                self?.padConnected = connected
                self?.show(connected ? L("手柄已连接：\(name)") : L("手柄已断开：\(name)"))
            }
        }
        startFrames()
        startPolling()
    }

    func shutdown() {
        frameTask?.cancel()
        pollTask?.cancel()
        if screenRecording { Task { await stopScreenRecording() } }
        send(keymaps.releaseAll())
        client.close()
    }

    /// `sticky`: stays until the next message (long installs and transfers).
    func show(_ msg: String, sticky: Bool = false) {
        toast = msg
        if sticky { return }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == msg { toast = nil }
        }
    }

    // MARK: Output to the guest (single choke point, so the recorder sees everything)

    func send(_ touches: [TouchPoint]) {
        guard !touches.isEmpty else { return }
        client.send(touches: touches)
        let now = CACurrentMediaTime()
        if let r = opRecorder {
            for t in touches where t.id < OperationPlayer.idOffset {
                r.record(.touch(id: t.id, x: t.x, y: t.y, down: t.down), now: now)
            }
        }
        if opState != .idle && Pref.d.bool(forKey: Pref.showTouches) { mark(touches) }
    }

    func sendKey(_ code: UInt16, down: Bool) {
        client.sendKey(macKeyCode: code, down: down)
        opRecorder?.record(.key(code: code, down: down), now: CACurrentMediaTime())
    }

    func sendAndroidKey(_ key: String) {
        client.sendAndroidKey(key)
        opRecorder?.record(.androidKey(key), now: CACurrentMediaTime())
    }

    func sendWheel(dx: Int32, dy: Int32) {
        client.sendWheel(dx: dx, dy: dy)
        opRecorder?.record(.wheel(dx: dx, dy: dy), now: CACurrentMediaTime())
    }

    private func mark(_ touches: [TouchPoint]) {
        for t in touches {
            touchMarks[t.id] = t.down ? CGPoint(x: Double(t.x) / Double(instance.width), y: Double(t.y) / Double(instance.height)) : nil
        }
    }

    // MARK: Frames

    private func startFrames() {
        let inst = instance
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kolibri/avd/\(inst.name).avd")
        do {
            renderer.frame = try SharedFrameBuffer(device: renderer.device, directory: dir, width: inst.width, height: inst.height)
        } catch {
            status = L("帧缓冲创建失败: \(error.localizedDescription)")
            return
        }
        // Self-built engine with IOSurface export: frames arrive on the GPU, no gRPC stream
        // (and so no per-frame readback in the engine).
        if ProcessInfo.processInfo.environment["KOLIBRI_NO_IOSURFACE"] == nil,
           let surfaces = IOSurfaceFrames(url: dir.appendingPathComponent(IOSurfaceFrames.fileName), device: renderer.device),
           surfaces.width == inst.width, surfaces.height == inst.height {
            renderer.surfaces = surfaces
            renderer.onSurfaceFrame = { [weak self] in
                if Thread.isMainThread { MainActor.assumeIsolated { self?.frameArrived() } }
                else { Task { @MainActor in self?.frameArrived() } }
            }
            return
        }
        let handle = renderer.frame!.url
        let client = self.client
        let renderer = self.renderer
        frameTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    try await client.streamFrames(handle: handle, width: inst.width, height: inst.height) { img in
                        // Copy the frame out before the engine overwrites it (not at the next refresh).
                        renderer.ingest()
                        self?.latestSeq = img.seq
                        Task { @MainActor in self?.frameArrived() }
                    }
                } catch {
                    await MainActor.run { self?.status = L("等待引擎画面…") }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private func frameArrived() {
        frameCount += 1
        if !status.isEmpty { status = "" }
    }

    private func tick(_ now: CFTimeInterval) {
        drawCount += 1
        if keymapEnabled { send(keymaps.tick(now: now)) }
        if let p = opPlayer { replay(p.tick(now: now)); if p.finished { playbackEnded() } }
        let dt = now - statsStart
        if dt >= 1 {
            guestFPS = Double(frameCount) / dt
            displayFPS = Double(drawCount) / dt
            if ProcessInfo.processInfo.environment["KOLIBRI_DEBUG"] != nil {
                print(String(format: "[stats] %@ guest %.1f fps, display %.1f Hz, seq %u, pkg %@",
                             instance.name, guestFPS, displayFPS, latestSeq, foregroundPackage ?? "-"))
            }
            writePerfLine()
            frameCount = 0
            drawCount = 0
            statsStart = now
        }
    }

    // MARK: Perf log

    private lazy var perfLog: FileHandle? = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kolibri/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("perf-\(instance.name).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)   // fresh log per session
        return try? FileHandle(forWritingTo: url)
    }()

    private func writePerfLine() {
        let win = NSApp.windows.first { $0.isVisible && $0.title.contains(instance.name) } ?? NSApp.keyWindow
        let (v, d, fs) = renderer.lastSizes
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let ctx = String(format: "%@ fs=%d key=%d every=%d screenHz=%d view=%.0fx%.0f drawable=%.0fx%.0f guest=%.1f",
                         f.string(from: Date()), fs ? 1 : 0, win?.isKeyWindow == true ? 1 : 0,
                         UserDefaults.standard.bool(forKey: "presentEveryRefresh") ? 1 : 0,
                         win?.screen?.maximumFramesPerSecond ?? 0, v.width, v.height, d.width, d.height, guestFPS)
        perfLog?.write((renderer.perf.line(context: ctx) + "\n").data(using: .utf8)!)
    }

    // MARK: Schemes follow the foreground game

    private func startPolling() {
        let name = instance.name
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // A failed or empty lookup (screen transition, adb hiccup) is not a game switch.
                if let pkg = await KolibriCtl.foregroundPackage(name), let self, pkg != self.foregroundPackage {
                    InputLog.write("foreground \(self.foregroundPackage ?? "-") -> \(pkg)")
                    self.foregroundPackage = pkg
                    self.reloadSchemes()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func schemes(_ kind: SchemeKind) -> [String] { KeymapStore.list(foregroundPackage, kind) }

    func isDisabled(_ kind: SchemeKind) -> Bool { KeymapStore.isDisabled(foregroundPackage, kind) }

    /// 「不使用方案」.
    func disableScheme(_ kind: SchemeKind) {
        KeymapStore.select(foregroundPackage, kind, "")
        reloadSchemes()
        show(L("已不使用\(kind.title)方案"))
    }

    /// 操作控制 › X/Y 轴灵敏度修正 (multiplies every mouse-look control).
    @Published var sensitivityX = Pref.d.double(forKey: Pref.aimSensX) {
        didSet { Pref.d.set(sensitivityX, forKey: Pref.aimSensX) }
    }
    @Published var sensitivityY = Pref.d.double(forKey: Pref.aimSensY) {
        didSet { Pref.d.set(sensitivityY, forKey: Pref.aimSensY) }
    }

    func scheme(_ kind: SchemeKind) -> Keymap { kind == .keyboard ? keyboardScheme : gamepadScheme }

    func reloadSchemes() {
        keyboardScheme = KeymapStore.active(foregroundPackage, .keyboard)
        gamepadScheme = KeymapStore.active(foregroundPackage, .gamepad)
        applyCombined()
    }

    private func applyCombined() {
        let k = KeymapStore.combined(keyboard: keyboardScheme, gamepad: gamepadScheme)
        let lifted = keymaps.load(k)   // empty when the scheme did not actually change
        if !lifted.isEmpty { InputLog.write("scheme changed to \(k.name), lifted \(lifted.count)") }
        send(lifted)
        if k != keymap { keymap = k }
    }

    func selectScheme(_ kind: SchemeKind, _ name: String) {
        KeymapStore.select(foregroundPackage, kind, name)
        reloadSchemes()
        show(L("已切换\(kind.title)方案：\(name)"))
    }

    /// Next/previous scheme.
    func cycleScheme(_ kind: SchemeKind, by step: Int) {
        let names = schemes(kind)
        guard names.count > 1 else { show(L("只有一个\(kind.title)方案")); return }
        let cur = names.firstIndex(of: scheme(kind).name) ?? 0
        selectScheme(kind, names[(cur + step + names.count) % names.count])
    }

    // MARK: 键位 menu actions

    func duplicateCurrent(_ kind: SchemeKind) {
        var k = scheme(kind)
        guard !k.name.isEmpty else { show(L("当前没有使用方案")); return }
        k.name = KeymapStore.uniqueName(foregroundPackage, kind, k.name + L(" 副本"))
        k.package = foregroundPackage
        try? KeymapStore.save(k, kind: kind)
        selectScheme(kind, k.name)
    }

    func deleteCurrent(_ kind: SchemeKind) {
        let name = scheme(kind).name
        guard !name.isEmpty else { show(L("当前没有使用方案")); return }
        let a = NSAlert()
        a.messageText = L("确定删除吗？")
        a.informativeText = L("删除后将无法恢复。")
        a.addButton(withTitle: L("删除"))
        a.addButton(withTitle: L("取消"))
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        KeymapStore.delete(foregroundPackage, kind, name)
        reloadSchemes()
    }

    func importScheme() {
        let panel = NSOpenPanel()
        panel.title = L("选择要导入的按键方案")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (k, kind) = try KeymapStore.importFile(url, package: foregroundPackage)
            KeymapStore.select(foregroundPackage, kind, k.name)
            reloadSchemes()
            show(L("导入按键方案成功"))
        } catch {
            show(L("导入按键方案失败，请重试"))
        }
    }

    func exportCurrent(_ kind: SchemeKind) {
        let k = scheme(kind)
        guard !k.name.isEmpty else { show(L("当前没有使用方案")); return }
        let panel = NSSavePanel()
        panel.title = L("导出按键方案")
        panel.nameFieldStringValue = "\(k.name).json"
        if panel.runModal() == .OK, let url = panel.url { try? KeymapStore.export(k, to: url) }
    }

    /// Start editing: the window switches to edit mode.
    @Published private(set) var editNew = false

    func beginEditing(_ kind: SchemeKind, newScheme: Bool) {
        focusLost()
        if pointerLocked { pointerLocked = false; CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() }
        editNew = newScheme
        editing = kind
    }

    /// 键位提示 › 透明度: applied live, saved into the active scheme.
    func setHintOpacity(_ v: Double, kind: SchemeKind) {
        var k = scheme(kind)
        guard !k.name.isEmpty else { return }
        k.hintOpacity = v
        if kind == .keyboard { keyboardScheme = k } else { gamepadScheme = k }
        keymap.hintOpacity = keyboardScheme.name.isEmpty ? v : keyboardScheme.hintOpacity
        try? KeymapStore.save(k, kind: kind)
    }

    func saveScheme(_ k: Keymap, kind: SchemeKind, replacing old: String?) {
        var k = k
        k.package = foregroundPackage
        if let old, old != k.name { KeymapStore.delete(k.package, kind, old) }
        do {
            try KeymapStore.save(k, kind: kind)
            KeymapStore.select(k.package, kind, k.name)
            reloadSchemes()
            show(L("已保存\(kind.title)方案：\(k.name)"))
        } catch {
            show(L("保存失败：\(error.localizedDescription)"))
        }
    }

    // MARK: Input entry points (called by GameDisplayView)

    var inputActive: Bool { keymapEnabled && editing == nil }

    func handle(binding: Binding, down: Bool) {
        guard inputActive else { return }
        let now = CACurrentMediaTime()
        send(down ? keymaps.press(binding, now: now) : keymaps.release(binding, now: now))
    }

    /// Whether a binding is used by the current schemes (otherwise it passes through).
    func isMapped(_ b: Binding) -> Bool {
        guard inputActive else { return false }
        if keymap.aimToggle == b { return true }
        return keymap.controls.contains { $0.triggers.contains(b) }
    }

    /// Unmapped input reaches Android unless the scheme turns passthrough off.
    var passKeyboard: Bool { !inputActive || keymap.passthrough.keyboard }
    var passMouse: Bool { !inputActive || keymap.passthrough.mouse }

    /// Scroll wheel: pinch-zoom when the scheme defines it, otherwise a real wheel.
    func wheel(notches: Double) {
        if inputActive, keymap.wheelZoom != nil {
            send(keymaps.wheel(notches: notches, now: CACurrentMediaTime()))
        } else if passMouse {
            sendWheel(dx: 0, dy: Int32(notches * 120))
        }
    }

    /// Trackpad pinch → the same two-finger zoom (only when the scheme uses zoom).
    func magnify(_ amount: Double) -> Bool {
        guard inputActive, keymap.wheelZoom != nil else { return false }
        send(keymaps.wheel(notches: amount * 12, now: CACurrentMediaTime()))
        return true
    }

    func mouseDelta(dx: Double, dy: Double) {
        guard inputActive, pointerLocked || keymaps.capturesMouse else { return }
        send(keymaps.mouseMoved(dx: dx * sensitivityX, dy: dy * sensitivityY))
    }

    /// Absolute cursor position in the guest (0...1), for 右键行走.
    func pointerMoved(_ p: NPoint) {
        guard inputActive else { return }
        send(keymaps.pointerMoved(to: p))
    }

    private func stick(_ name: String, _ x: Double, _ y: Double) {
        guard inputActive else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastStickTick, 0.05)
        lastStickTick = now
        send(keymaps.stick(name, x: x, y: y, dt: dt))
    }

    func focusLost(_ reason: String = "") {
        let lifted = keymaps.releaseAll()
        if !lifted.isEmpty { InputLog.write("release all (\(reason.isEmpty ? "ui" : reason)): \(lifted.count) fingers") }
        send(lifted)
    }

    /// Pointer unlocked: only the mouse-look fingers lift.
    func pointerUnlocked() {
        send(keymaps.releaseMouseControls())
    }

    // MARK: Operation recorder

    func startOperationRecording() {
        guard opState == .idle else { return }
        focusLost()
        opRecorder = OperationRecorder(now: CACurrentMediaTime())
        opPaused = false
        opState = .recording
        show(L("开始录制操作（请不要输入密码等敏感信息）"))
    }

    func togglePauseOperation() {
        let now = CACurrentMediaTime()
        if let r = opRecorder {
            if r.paused { r.resume(now: now) } else { focusLost(); r.pause(now: now) }
            opPaused = r.paused
        } else if let p = opPlayer {
            if p.paused { p.resume(now: now) } else { replay(p.pause(now: now)) }
            opPaused = p.paused
        }
    }

    func operationElapsed(_ now: CFTimeInterval) -> Double {
        if let r = opRecorder { return r.elapsed(now: now) }
        if let p = opPlayer { return p.position(now: now) }
        return 0
    }

    var operationRound: (Int, Int)? {
        opPlayer.map { ($0.round, $0.recording.repeatTimes) }
    }

    /// Stop recording (saving it) or stop playback.
    func stopOperation() {
        let now = CACurrentMediaTime()
        if let r = opRecorder {
            focusLost()
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH.mm.ss"
            let rec = r.finish(name: "\(foregroundPackage?.split(separator: ".").last.map(String.init) ?? L("录制")) \(f.string(from: Date()))",
                               package: foregroundPackage, width: instance.width, height: instance.height, now: now)
            opRecorder = nil
            if rec.events.isEmpty {
                show(L("没有录到任何操作"))
            } else if (try? RecordingStore.save(rec)) != nil {
                show(L("已保存操作录制「\(rec.name)」（\(String(format: "%.1f", rec.duration)) 秒）"))
            }
        } else if let p = opPlayer {
            replay(p.stop())
            playbackEnded()
        }
        opState = .idle
        opPaused = false
        touchMarks = [:]
    }

    func play(_ rec: OperationRecording) {
        guard opState == .idle else { return }
        if let pkg = rec.package, let cur = foregroundPackage, pkg != cur {
            show(L("提示：这段录制来自 \(pkg)"))
        }
        opPlayer = OperationPlayer(rec, screenWidth: instance.width, screenHeight: instance.height, now: CACurrentMediaTime())
        opPaused = false
        opState = .playing(rec.name)
    }

    private func replay(_ events: [OperationRecording.Event]) {
        var touches: [TouchPoint] = []
        for e in events {
            switch e {
            case let .touch(id, x, y, d): touches.append(TouchPoint(id: id, x: x, y: y, down: d))
            case let .key(code, d): client.sendKey(macKeyCode: code, down: d)
            case let .androidKey(k): client.sendAndroidKey(k)
            case let .wheel(dx, dy): client.sendWheel(dx: dx, dy: dy)
            }
        }
        send(touches)
    }

    private func playbackEnded() {
        if let p = opPlayer { show(L("「\(p.recording.name)」执行完毕")) }
        opPlayer = nil
        opState = .idle
        touchMarks = [:]
    }

    // MARK: Screenshot & screen recording

    func screenshot() {
        guard let img = renderer.frame?.cgImage() else { show(L("还没有画面")); return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = mediaURL(.picturesDirectory, ext: "png")
        do {
            try png.write(to: url)
            if Pref.d.bool(forKey: Pref.screenshotToClipboard) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: .zero)])
            }
            show(L("截图已保存：\(url.lastPathComponent)"))
        } catch {
            show(L("截图失败：\(error.localizedDescription)"))
        }
    }

    func toggleScreenRecording() {
        if screenRecording { Task { await stopScreenRecording() } } else { startScreenRecording() }
    }

    private func startScreenRecording() {
        let codec = ScreenRecorder.Codec(rawValue: Pref.d.string(forKey: Pref.recordCodec) ?? "") ?? .hevc
        // Holder lets the audio callback reach the recorder that is created right after it.
        final class Sink: @unchecked Sendable { var recorder: ScreenRecorder? }
        let sink = Sink()
        let withAudio = Pref.d.bool(forKey: Pref.recordAudio)
        do {
            let r = try ScreenRecorder(url: mediaURL(.moviesDirectory, ext: "mp4"), width: instance.width, height: instance.height,
                                       codec: codec, fps: max(instance.refresh_hz, 60), device: renderer.device,
                                       audio: withAudio ? EngineAudioStream.format : nil)
            sink.recorder = r
            screenRecorder = r
            if withAudio {
                audioStream = EngineAudioStream(client: client) { pcm, frames, host in
                    sink.recorder?.appendAudio(pcm, frames: frames, hostTime: host)
                }
            }
            renderer.recorder = r
            screenRecording = true
            show(L("开始录屏（\(codec.title)）"))
        } catch {
            show(L("无法录屏：\(error.localizedDescription)"))
        }
    }

    func screenRecordingElapsed() -> Double { screenRecorder?.elapsed ?? 0 }

    func stopScreenRecording() async {
        guard let r = screenRecorder else { return }
        renderer.recorder = nil
        audioStream?.stop()
        audioStream = nil
        screenRecorder = nil
        screenRecording = false
        lastRecordingStats = (r.frames, r.audioPackets)
        if let url = await r.finish() {
            show(L("录屏已保存：\(url.lastPathComponent)（\(r.frames) 帧）"))
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            show(L("录屏失败或没有画面"))
        }
    }

    private func mediaURL(_ base: FileManager.SearchPathDirectory, ext: String) -> URL {
        let dir = FileManager.default.urls(for: base, in: .userDomainMask)[0].appendingPathComponent("Kolibri", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("\(instance.name)-\(f.string(from: Date())).\(ext)")
    }

    // MARK: Toolbar actions

    nonisolated static func isPackage(_ url: URL) -> Bool {
        ["apk", "xapk", "apks", "apkm"].contains(url.pathExtension.lowercased())
    }

    /// Dropped onto the game window (or picked with 安装APK): packages install, operation
    /// recordings import, anything else (files or folders) goes to the guest's Download folder.
    func handleDrop(_ urls: [URL]) {
        Task {
            for (i, url) in urls.enumerated() {
                let n = urls.count > 1 ? "（\(i + 1)/\(urls.count)）" : ""
                let name = url.lastPathComponent
                if Self.isPackage(url) {
                    show(L("正在安装 \(name)…\(n)"), sticky: true)
                    show(await installAPK(url) + n, sticky: i < urls.count - 1)
                } else if url.pathExtension.lowercased() == "vprec" {
                    show((try? RecordingStore.importFile(url)) != nil ? L("已导入操作录制 \(name)") : L("导入失败：\(name)"))
                } else {
                    show(L("正在传输 \(name)…\(n)"), sticky: true)
                    show(await pushFile(url) + n, sticky: i < urls.count - 1)
                }
            }
        }
    }

    /// .apk, or a split-APK bundle (.xapk / .apks / .apkm: a zip of APKs, .xapk may carry OBB data).
    func installAPK(_ url: URL) async -> String {
        let name = url.deletingPathExtension().lastPathComponent
        do {
            if url.pathExtension.lowercased() == "apk" {
                _ = try await KolibriCtl.adb(instance.name, ["install", "-r", "-g", url.path])
            } else {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kolibri-bundle-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: dir) }
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", url.path, dir.path]
                try unzip.run()
                unzip.waitUntilExit()
                let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
                let apks = files.filter { $0.pathExtension.lowercased() == "apk" }.map(\.path)
                guard !apks.isEmpty else { return L("安装失败：\(name) 里没有安装包") }
                _ = try await KolibriCtl.adb(instance.name, ["install-multiple", "-r", "-g"] + apks)
                // .xapk game data: Android/obb/<package>/...
                let obb = dir.appendingPathComponent("Android/obb")
                if FileManager.default.fileExists(atPath: obb.path) {
                    _ = try? await KolibriCtl.adb(instance.name, ["push", obb.path + "/.", "/sdcard/Android/obb/"])
                }
            }
            return L("安装成功：\(name)")
        } catch {
            return L("安装失败：\(name)，") + Self.installError(error.localizedDescription)
        }
    }

    /// adb's INSTALL_FAILED_* codes in words.
    private static func installError(_ raw: String) -> String {
        let table: [(String, String)] = [
            ("NO_MATCHING_ABIS", L("只有 32 位版本，请下载 ARM64 版本")),
            ("INSUFFICIENT_STORAGE", L("安卓存储空间不足，请清理后重试")),
            ("VERSION_DOWNGRADE", L("已安装更高版本")),
            ("UPDATE_INCOMPATIBLE", L("和已安装的版本签名不同，请先卸载旧版")),
            ("INVALID_APK", L("安装包已损坏，请重新下载")),
            ("OLDER_SDK", L("这个版本不支持安卓 16")),
        ]
        return table.first { raw.contains($0.0) }?.1 ?? raw.split(separator: "\n").last.map(String.init) ?? raw
    }

    /// A file or folder into the guest's Download folder, indexed so 文件 and apps see it.
    func pushFile(_ url: URL) async -> String {
        let target = "/sdcard/Download/" + url.lastPathComponent
        do {
            _ = try await KolibriCtl.adb(instance.name, ["push", url.path, "/sdcard/Download/"])
            _ = try? await KolibriCtl.adb(instance.name, ["shell", "am", "broadcast", "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                                                          "-d", "file://" + target])
            return L("已传到安卓「下载」：\(url.lastPathComponent)")
        } catch {
            return L("传输失败：\(url.lastPathComponent)")
        }
    }

    static let sharedFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(L("Kolibri 共享"), isDirectory: true)
    static let guestShared = "/sdcard/KolibriShared"

    /// 共享文件夹: two-way sync between ~/Documents/Kolibri 共享 and /sdcard/KolibriShared.
    func syncSharedFolder() async {
        let host = Self.sharedFolder
        try? FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        show(L("正在同步共享文件夹…"))
        _ = try? await KolibriCtl.adb(instance.name, ["shell", "mkdir", "-p", Self.guestShared])
        let up = try? await KolibriCtl.adb(instance.name, ["push", "--sync", host.path + "/.", Self.guestShared])
        let down = try? await KolibriCtl.adb(instance.name, ["pull", "-a", Self.guestShared + "/.", host.path])
        NSWorkspace.shared.open(host)
        show(up != nil && down != nil ? L("共享文件夹已同步（安卓：\(Self.guestShared)）") : L("同步失败"))
    }

    /// Opens Terminal with an adb shell into this instance.
    func openADB() {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("kolibri-adb-\(instance.name).command")
        let script = "#!/bin/bash\nclear\necho 'Kolibri ADB · \(instance.name) (\(instance.serial))'\nexec /usr/bin/python3 '\(KolibriCtl.scriptURL.path)' adb '\(instance.name)' shell\n"
        try? script.write(to: f, atomically: true, encoding: .utf8)
        chmod(f.path, 0o755)
        NSWorkspace.shared.open(f)
    }

    func shake() { Task { await client.shake() } }

    func pasteToAndroid() {
        guard let text = NSPasteboard.general.string(forType: .string) else { show(L("剪贴板里没有文字")); return }
        Task { await client.setClipboard(text); show(L("已同步剪贴板到安卓")) }
    }

    func rotate() async {
        let cur = (try? await KolibriCtl.adb(instance.name, ["shell", "settings", "get", "system", "user_rotation"])) ?? "0"
        let next = (Int(cur) ?? 0) == 0 ? 1 : 0
        _ = try? await KolibriCtl.adb(instance.name, ["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
        _ = try? await KolibriCtl.adb(instance.name, ["shell", "settings", "put", "system", "user_rotation", "\(next)"])
    }

    func setVMPaused(_ paused: Bool) {
        Task { await client.setPaused(paused) }
    }
}
