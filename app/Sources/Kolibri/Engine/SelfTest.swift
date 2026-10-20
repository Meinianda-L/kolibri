import AVFoundation
import AppKit
import QuartzCore
import Metal
import SwiftUI
import KolibriCore

/// `Kolibri --selftest <instance>`: headless end-to-end check against a
/// running instance. Drives screenshot, screen recording (video + audio) and
/// operation record/replay, prints one line per check, exits non-zero on failure.
/// Files it creates are removed afterwards.
@MainActor
enum SelfTest {
    static func run(_ name: String) {
        Task {
            var ok = true
            func check(_ label: String, _ pass: Bool, _ detail: String = "") {
                print("\(pass ? "PASS" : "FAIL")  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
                ok = ok && pass
            }
            do {
                guard let inst = try await KolibriCtl.list().first(where: { $0.name == name && $0.running }) else {
                    print("FAIL  instance \(name) is not running"); exit(2)
                }
                let s = try GameSession(instance: inst)
                let r = s.renderer
                let pump = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in r.pumpOffscreen() }
                RunLoop.main.add(pump, forMode: .common)
                let w = inst.width, h = inst.height
                // A one-finger drag across the screen makes the guest draw new frames.
                @MainActor func drag(_ id: Int32 = 950) async {
                    for k in 0...20 {
                        s.send([TouchPoint(id: id, x: Int32(w / 2), y: Int32(Double(h) * (0.75 - Double(k) * 0.02)), down: true)])
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                    s.send([TouchPoint(id: id, x: Int32(w / 2), y: Int32(Double(h) * 0.35), down: false)])
                }

                s.sendAndroidKey("GoHome")
                let t0 = Date()
                while s.renderer.frameSerial == 0 && Date().timeIntervalSince(t0) < 15 {
                    await drag()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                check("frames via shared memory", s.renderer.frameSerial > 0, "\(s.renderer.frameSerial) frames")

                // Screenshot
                let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kolibri")
                let before = Set((try? FileManager.default.contentsOfDirectory(atPath: pics.path)) ?? [])
                s.screenshot()
                let shot = ((try? FileManager.default.contentsOfDirectory(atPath: pics.path)) ?? []).first { !before.contains($0) }
                if let shot, let img = NSImage(contentsOf: pics.appendingPathComponent(shot)),
                   let rep = img.representations.first {
                    check("screenshot", rep.pixelsWide == w && rep.pixelsHigh == h, "\(shot) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                    try? FileManager.default.removeItem(at: pics.appendingPathComponent(shot))
                } else {
                    check("screenshot", false, s.toast ?? "no file")
                }

                // Screen recording (HEVC + guest audio). Touch sounds give the guest something to play.
                let sfx = try? await KolibriCtl.adb(name, ["shell", "settings", "get", "system", "sound_effects_enabled"])
                _ = try? await KolibriCtl.adb(name, ["shell", "settings", "put", "system", "sound_effects_enabled", "1"])
                let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Kolibri")
                let mBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: movies.path)) ?? [])
                // An 8 s 440 Hz tone played by the guest's music app (audio only streams while the guest plays).
                let tone = FileManager.default.temporaryDirectory.appendingPathComponent("kolibri_tone.wav")
                try? toneWAV().write(to: tone)
                _ = try? await KolibriCtl.adb(name, ["push", tone.path, "/sdcard/Download/kolibri_tone.wav"])
                _ = try? await KolibriCtl.adb(name, ["shell", "am", "start", "-a", "android.intent.action.VIEW",
                                                  "-d", "file:///sdcard/Download/kolibri_tone.wav", "-t", "audio/wav"])
                try? await Task.sleep(for: .milliseconds(800))
                s.toggleScreenRecording()
                check("screen recording started", s.screenRecording, s.toast ?? "")
                for _ in 0..<6 {
                    await drag()
                    s.sendAndroidKey("AppSwitch")      // UI clicks make sound
                    try? await Task.sleep(for: .milliseconds(300))
                    s.sendAndroidKey("GoHome")
                    try? await Task.sleep(for: .milliseconds(300))
                }
                await s.stopScreenRecording()
                _ = try? await KolibriCtl.adb(name, ["shell", "am", "force-stop", "com.android.music"])
                _ = try? await KolibriCtl.adb(name, ["shell", "rm", "-f", "/sdcard/Download/kolibri_tone.wav"])
                try? FileManager.default.removeItem(at: tone)
                _ = try? await KolibriCtl.adb(name, ["shell", "settings", "put", "system", "sound_effects_enabled", (sfx ?? "1").isEmpty ? "1" : sfx!])
                print("      recorder: \(s.lastRecordingStats.0) frames, \(s.lastRecordingStats.1) audio packets")
                if let f = ((try? FileManager.default.contentsOfDirectory(atPath: movies.path)) ?? []).first(where: { !mBefore.contains($0) }) {
                    let url = movies.appendingPathComponent(f)
                    let asset = AVURLAsset(url: url)
                    let dur = (try? await asset.load(.duration).seconds) ?? 0
                    let v = (try? await asset.loadTracks(withMediaType: .video)) ?? []
                    let a = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
                    var size = CGSize.zero
                    if let t = v.first { size = (try? await t.load(.naturalSize)) ?? .zero }
                    check("screen recording file", dur > 1.5 && !v.isEmpty && Int(size.width) == w,
                          String(format: "%.1fs, %.0fx%.0f, video %d, audio %d", dur, size.width, size.height, v.count, a.count))
                    check("screen recording audio track", !a.isEmpty)
                    try? FileManager.default.removeItem(at: url)
                } else {
                    check("screen recording file", false, s.toast ?? "")
                }
                // stopScreenRecording reveals the file in Finder; that is fine for users, noisy here.
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.hide()

                // Operation recorder: record a drag, then replay it twice at 2x.
                let recBefore = Set(RecordingStore.list().map(\.url))
                s.startOperationRecording()
                await drag(1)
                try? await Task.sleep(for: .milliseconds(300))
                s.sendAndroidKey("GoHome")
                s.stopOperation()
                guard let item = RecordingStore.list().first(where: { !recBefore.contains($0.url) }) else {
                    check("operation recording saved", false, s.toast ?? ""); finish(ok); return
                }
                let touches = item.recording.events.filter { if case .touch = $0.e { return true } else { return false } }
                check("operation recording saved", touches.count >= 20,
                      String(format: "%d events, %.2fs", item.recording.events.count, item.recording.duration))
                var rec = item.recording
                rec.repeatTimes = 2
                rec.speed = 2
                s.play(rec)
                let p0 = Date()
                var rounds = 0
                while s.opState != .idle && Date().timeIntervalSince(p0) < 10 {
                    rounds = max(rounds, s.operationRound?.0 ?? 0)
                    try? await Task.sleep(for: .milliseconds(20))
                }
                let took = Date().timeIntervalSince(p0)
                let expected = rec.duration / rec.speed * 2
                check("operation replay x2 @2×", s.opState == .idle && rounds == 2 && abs(took - expected) < 0.6,
                      String(format: "%.2fs (expected ≈%.2fs)", took, expected))
                RecordingStore.delete(item)

                pump.invalidate()
                s.shutdown()
            } catch {
                check("session", false, error.localizedDescription)
            }
            finish(ok)
        }
    }

    /// 8 s, 48 kHz stereo, 440 Hz sine as a WAV file.
    private static func toneWAV() -> Data {
        let rate = 48_000, seconds = 8, n = rate * seconds
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n * 4); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n * 4)
        var pcm = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            pcm[2 * i] = v
            pcm[2 * i + 1] = v
        }
        pcm.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: n * 4)) }
        return d
    }

    /// `--touchtest <instance> <scenario>`: hold finger 0 (a walk stick) while other
    /// fingers come and go, so `getevent` in the guest shows whether finger 0 ever lifts.
    static func touchTest(_ name: String, scenario: String) {
        Task.detached {
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let c = try? EmulatorClient(port: inst.grpc_port) else { print("no instance"); exit(2) }
            let w = Int32(inst.width), h = Int32(inst.height)
            func p(_ x: Double, _ y: Double) -> (Int32, Int32) { (Int32(Double(w) * x), Int32(Double(h) * y)) }
            let ids: [Int32] = [8, 16, 24, 900, 1000, 1001, 2000, 40, 48, 56, 64, 72, 80, 88, 96, 104]
            if scenario == "wasd" {
                // The real keymap engine driving a WASD stick at 120 Hz: D, then W (up-right),
                // then A while D is still held (A wins), then release everything.
                // Center/radius from the user's Luanti scheme (~/.kolibri/keymaps/net.minetest.minetest).
                let env = ProcessInfo.processInfo.environment
                let cx = Double(env["WASD_X"] ?? "") ?? 0.1149, cy = Double(env["WASD_Y"] ?? "") ?? 0.8007
                let rad = Double(env["WASD_R"] ?? "") ?? 0.0397
                let wasd = Control.joystick(up: .key(13), down: .key(1), left: .key(0), right: .key(2),
                                            center: NPoint(cx, cy), radius: rad, stick: nil)
                let e = KeymapEngine(keymap: Keymap(name: "t", controls: [wasd]), screenWidth: Int(w), screenHeight: Int(h))
                let t0 = CACurrentMediaTime()
                // W for 3 s, then W+A for 2 s, then let go. WASD_KEY holds one key for 3 s instead;
                // WASD_JUMP=1 replays the old engine (centre and rim in one event) for comparison.
                var script: [(Double, KolibriCore.Binding, Bool)] = [(0.5, .key(13), true), (3.5, .key(0), true),
                                                         (5.5, .key(0), false), (5.5, .key(13), false)]
                if let k = env["WASD_KEY"].flatMap(UInt16.init) { script = [(0.5, .key(k), true), (3.5, .key(k), false)] }
                if env["WASD_JUMP"] == "1", let k = env["WASD_KEY"].flatMap(UInt16.init) {
                    let (x, y) = p(cx, cy)
                    let dx: Int32 = k == 2 ? 1 : k == 0 ? -1 : 0, dy: Int32 = k == 1 ? 1 : k == 13 ? -1 : 0
                    let r = Int32(rad * Double(w))
                    c.send(touches: [TouchPoint(id: 0, x: x, y: y, down: true), TouchPoint(id: 0, x: x + dx * r, y: y + dy * r, down: true)])
                    try? await Task.sleep(for: .seconds(3))
                    c.send(touches: [TouchPoint(id: 0, x: x + dx * r, y: y + dy * r, down: false)])
                    try? await Task.sleep(for: .milliseconds(300))
                    print("done jump"); exit(0)
                }
                var next = 0
                while CACurrentMediaTime() - t0 < 6.0 {
                    let now = CACurrentMediaTime() - t0
                    var out: [TouchPoint] = []
                    while next < script.count, script[next].0 <= now {
                        let (_, b, down) = script[next]
                        out += down ? e.press(b, now: now) : e.release(b, now: now)
                        next += 1
                    }
                    out += e.tick(now: now)
                    if !out.isEmpty {
                        c.send(touches: out)
                        for t in out { print(String(format: "t=%.3f id=%d %@ (%d,%d)", now, t.id, t.down ? "down" : "up", t.x, t.y)) }
                    }
                    try? await Task.sleep(for: .milliseconds(8))
                }
                try? await Task.sleep(for: .milliseconds(300))
                print("done wasd")
                exit(0)
            }
            let start = Date()
            var k = 0
            let (sx, sy) = p(0.2, 0.7)
            c.send(touches: [TouchPoint(id: 0, x: sx, y: sy, down: true)])
            while Date().timeIntervalSince(start) < (scenario == "long" ? 90 : 6) {
                // Walk stick wiggles every frame.
                let t = Date().timeIntervalSince(start)
                c.send(touches: [TouchPoint(id: 0, x: sx + Int32(40 * sin(t * 6)), y: sy, down: true)])
                if k % 6 == 0 && scenario != "long" {
                    let id = ids[(k / 6) % ids.count]
                    let (x, y) = p(0.6 + Double((k / 6) % 4) * 0.08, 0.4)
                    switch scenario {
                    case "batch":   // what aim recentering sends: up + down of one id in one event
                        c.send(touches: [TouchPoint(id: id, x: x, y: y, down: true)])
                        c.send(touches: [TouchPoint(id: id, x: x, y: y, down: false), TouchPoint(id: id, x: x + 30, y: y, down: true)])
                        c.send(touches: [TouchPoint(id: id, x: x + 30, y: y, down: false)])
                    case "ghost":   // lifting fingers that were never down (releaseAll)
                        c.send(touches: [TouchPoint(id: id, x: 0, y: 0, down: false)])
                    default:        // plain taps
                        c.send(touches: [TouchPoint(id: id, x: x, y: y, down: true)])
                        try? await Task.sleep(for: .milliseconds(40))
                        c.send(touches: [TouchPoint(id: id, x: x, y: y, down: false)])
                    }
                }
                k += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            c.send(touches: [TouchPoint(id: 0, x: sx, y: sy, down: false)])
            try? await Task.sleep(for: .milliseconds(300))
            print("done \(scenario)")
            exit(0)
        }
    }

    /// `--uisnap <instance> <dir>`: render the keymap UI over the live game frame to PNGs
    /// (editor with the add menu, a focused key with settings, the popover, hints).
    static func uiSnap(_ name: String, dir: String) {
        Task { @MainActor in
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let s = try? GameSession(instance: inst) else { print("no instance"); exit(2) }
            let r = s.renderer
            let pump = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in r.pumpOffscreen() }
            RunLoop.main.add(pump, forMode: .common)
            try? await Task.sleep(for: .seconds(3))
            let frame = s.renderer.frame?.cgImage()
            let size = CGSize(width: 1280, height: 720)
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            var demo = Keymap(name: "自定义方案", controls: [
                ControlKind.dpad.make(at: NPoint(0.14, 0.72), pad: false),
                ControlKind.crosshair.make(at: NPoint(0.62, 0.45), pad: false),
                ControlKind.fire.make(at: NPoint(0.86, 0.66), pad: false),
                ControlKind.spell.make(at: NPoint(0.74, 0.80), pad: false),
                ControlKind.click.make(at: NPoint(0.93, 0.48), pad: false),
                ControlKind.burstTap.make(at: NPoint(0.66, 0.88), pad: false),
                .button(binding: .key(49), at: NPoint(0.80, 0.50), mode: .hold),   // 空格 twice → conflict
                ControlKind.curve.make(at: NPoint(0.35, 0.30), pad: false),
            ], aimToggle: .key(50))
            demo.setExtra(4, ControlExtra(note: "跳"))

            @MainActor func save<V: View>(_ v: V, _ file: String) {
                let view = ZStack {
                    if let frame { Image(decorative: frame, scale: 1).resizable().aspectRatio(contentMode: .fit) } else { Color.black }
                    v
                }
                .frame(width: size.width, height: size.height).background(Color.black)
                .environment(\.colorScheme, .dark)
                let ir = ImageRenderer(content: view)
                ir.scale = 2
                if let img = ir.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: out.appendingPathComponent(file))
                    print("wrote \(file)")
                }
            }
            save(KeymapEditor(session: s, kind: .keyboard, preview: .init(draft: demo, menuAt: CGPoint(x: 420, y: 260))), "1-edit-menu.png")
            save(KeymapEditor(session: s, kind: .keyboard, preview: .init(draft: demo, focused: 3, settingsFor: 3)), "2-edit-settings.png")
            save(KeymapEditor(session: s, kind: .keyboard, preview: .init(draft: demo, focused: 0, slot: 2)), "3-edit-direction.png")
            save(KeymapEditor(session: s, kind: .keyboard, preview: .init(draft: Keymap(name: "自定义方案", controls: []))), "4-edit-empty.png")
            save(KeymapHints(keymap: demo, width: inst.width, height: inst.height), "5-hints.png")
            save(KeymapPopover(session: s, kind: .keyboard, close: {}).background(.regularMaterial).fixedSize(), "6-popover.png")
            pump.invalidate()
            s.shutdown()
            exit(0)
        }
    }

    /// `--androidkey <instance> <key>`: send one Android key exactly like the toolbar does
    /// (gRPC key name, e.g. AppSwitch / GoHome / GoBack).
    static func androidKey(_ name: String, key: String) {
        Task.detached {
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let c = try? EmulatorClient(port: inst.grpc_port) else { print("no instance"); exit(2) }
            try? await Task.sleep(for: .milliseconds(300))
            c.sendAndroidKey(key)
            try? await Task.sleep(for: .milliseconds(500))
            print("sent \(key)")
            exit(0)
        }
    }

    /// `--framecheck <instance> <seconds>`: a second, passive MMAP frame stream that checks
    /// the order of what the engine delivers: seq/timestamp going backwards, and frames that
    /// look like an older frame than the one just before (a stale frame shown again).
    static func frameCheck(_ name: String, seconds: Double) {
        Task.detached {
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let c = try? EmulatorClient(port: inst.grpc_port), let dev = MTLCreateSystemDefaultDevice(),
                  let fb = try? SharedFrameBuffer(device: dev, directory: FileManager.default.temporaryDirectory.appendingPathComponent("kolibri-framecheck"),
                                                  width: inst.width, height: inst.height) else { print("no instance"); exit(2) }
            final class St: @unchecked Sendable {
                var hist: [(seq: UInt32, ts: UInt64, g: [UInt8])] = []
                var frames = 0, seqBack = 0, tsBack = 0, stale = 0, dup = 0
                var gaps: [Double] = []
                var tsGaps: [Double] = []
                var moving = 0
                var last = CACurrentMediaTime()
                // Safe window: time from a frame notification until the engine starts
                // overwriting the shared buffer with the next frame.
                var notifiedAt = 0.0
                var notifiedGrid: [UInt8] = []
                var windowOpen = false
                var windows: [Double] = []
                let lock = NSLock()
            }
            let st = St()
            @Sendable func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
                var s = 0; for i in a.indices { s += abs(Int(a[i]) - Int(b[i])) }; return Double(s) / Double(a.count)
            }
            let t = Task.detached {
                try? await c.streamFrames(handle: fb.url, width: inst.width, height: inst.height) { img in
                    let g = fb.lumaGrid(cols: 96, rows: 54)
                    let now = CACurrentMediaTime()
                    st.gaps.append((now - st.last) * 1000); st.last = now
                    st.frames += 1
                    if let p = st.hist.last {
                        st.tsGaps.append(Double(Int64(img.timestampUs) - Int64(p.ts)) / 1000)
                        if img.seq <= p.seq { st.seqBack += 1 }
                        if img.timestampUs < p.ts { st.tsBack += 1 }
                        let dPrev = diff(g, p.g)
                        if dPrev < 0.05 { st.dup += 1 }
                        if dPrev > 3 { st.moving += 1 }
                        // Closer to a frame 2..6 back than to the previous one, while the scene moves.
                        if dPrev > 3, st.hist.count >= 3 {
                            let older = st.hist.dropLast().suffix(5).map { diff(g, $0.g) }
                            if let m = older.min(), m < dPrev * 0.5 {
                                st.stale += 1
                                print(String(format: "stale? seq=%u dPrev=%.1f dOlder=%.1f", img.seq, dPrev, m))
                            }
                        }
                    }
                    st.hist.append((img.seq, img.timestampUs, g)); if st.hist.count > 8 { st.hist.removeFirst() }
                    st.lock.lock(); st.notifiedAt = now; st.notifiedGrid = fb.lumaGrid(cols: 48, rows: 27); st.windowOpen = true; st.lock.unlock()
                }
            }
            let poller = Thread {
                while !Thread.current.isCancelled {
                    st.lock.lock()
                    if st.windowOpen, fb.lumaGrid(cols: 48, rows: 27) != st.notifiedGrid {
                        st.windows.append((CACurrentMediaTime() - st.notifiedAt) * 1000)
                        st.windowOpen = false
                    }
                    st.lock.unlock()
                    usleep(300)
                }
            }
            poller.start()
            try? await Task.sleep(for: .seconds(seconds))
            poller.cancel()
            t.cancel()
            st.lock.lock()
            let w = st.windows.sorted()
            st.lock.unlock()
            func wp(_ q: Double) -> Double { w.isEmpty ? 0 : w[min(w.count - 1, Int(Double(w.count) * q))] }
            print(String(format: "safe window ms (notify -> engine starts next write): p1=%.1f p5=%.1f p50=%.1f  <8ms: %d of %d",
                         wp(0.01), wp(0.05), wp(0.5), w.filter { $0 < 8 }.count, w.count))
            let gaps = st.gaps.dropFirst().sorted()
            func pct(_ q: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * q))] }
            print(String(format: "frames=%d (%.1f fps) moving=%d seq_back=%d ts_back=%d identical=%d stale=%d",
                         st.frames, Double(st.frames) / seconds, st.moving, st.seqBack, st.tsBack, st.dup, st.stale))
            print(String(format: "arrival gap ms   p50=%.1f p95=%.1f p99=%.1f max=%.1f  >50ms: %d",
                         pct(0.5), pct(0.95), pct(0.99), gaps.last ?? 0, gaps.filter { $0 > 50 }.count))
            let ts = st.tsGaps.sorted()
            func tp(_ q: Double) -> Double { ts.isEmpty ? 0 : ts[min(ts.count - 1, Int(Double(ts.count) * q))] }
            print(String(format: "engine ts gap ms p50=%.1f p95=%.1f p99=%.1f max=%.1f  >50ms: %d",
                         tp(0.5), tp(0.95), tp(0.99), ts.last ?? 0, ts.filter { $0 > 50 }.count))
            exit(0)
        }
    }

    /// `--audiotest <instance> <seconds>`: count what the engine's gRPC audio stream
    /// delivers (packets, bytes, peak level) while something plays in the guest.
    static func audioTest(_ name: String, seconds: Double) {
        Task { @MainActor in
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let client = try? EmulatorClient(port: inst.grpc_port) else { print("no instance"); exit(2) }
            final class Stats: @unchecked Sendable { var packets = 0, bytes = 0, peak: Int16 = 0, loud = 0 }
            let st = Stats()
            let t = Task.detached {
                do {
                    try await client.streamAudio { data, _ in
                        st.packets += 1; st.bytes += data.count
                        data.withUnsafeBytes { raw in
                            var packetPeak: Int16 = 0
                            for v in raw.bindMemory(to: Int16.self) where v != .min { packetPeak = max(packetPeak, abs(v)) }
                            st.peak = max(st.peak, packetPeak)
                            if packetPeak > 300 { st.loud += 1 }
                        }
                    }
                } catch { print("stream error: \(error)") }
            }
            for s in stride(from: 1.0, through: seconds, by: 1.0) {
                try? await Task.sleep(for: .seconds(1))
                // Per second: 48 kHz s16 stereo is 192000 bytes of audio.
                print(String(format: "t=%2.0fs packets=%d bytes=%d (%.2f s of audio) peak=%d loud=%d",
                             s, st.packets, st.bytes, Double(st.bytes) / 192_000, st.peak, st.loud))
                st.packets = 0; st.bytes = 0; st.peak = 0; st.loud = 0
            }
            t.cancel()
            exit(0)
        }
    }

    /// `--renderload <instance> <WxH> <old|new> <seconds>`: present the live game at a
    /// window size, 120 times a second, offscreen. Run a game benchmark meanwhile to see
    /// how much the display path costs the game.
    static func renderLoad(_ name: String, size: String, mode: String, seconds: Double) {
        Task { @MainActor in
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let s = try? GameSession(instance: inst) else { print("no instance"); exit(2) }
            s.renderer.measureIngest = true
            let wh = size.split(separator: "x").compactMap { Int($0) }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: wh[0], height: wh[1], mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .private
            let target = s.renderer.device.makeTexture(descriptor: d)!
            s.renderer.tiledPresent = mode == "new"
            let r = s.renderer
            final class Count: @unchecked Sendable { var drawn = 0, ticks = 0 }
            let c = Count()
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                c.ticks += 1
                if r.presentOffscreen(into: target) { c.drawn += 1 }
            }
            RunLoop.main.add(t, forMode: .common)
            try? await Task.sleep(for: .seconds(seconds))
            t.invalidate()
            let ms = s.renderer.ingestMs.sorted()
            if !ms.isEmpty {
                func q(_ p: Double) -> Double { ms[min(ms.count - 1, Int(Double(ms.count) * p))] }
                print(String(format: "frame copy-out after notify: n=%d p50=%.2f ms p99=%.2f ms max=%.2f ms", ms.count, q(0.5), q(0.99), ms.last!))
            }
            print("renderload \(mode) \(size): \(c.ticks) refreshes, \(c.drawn) drawn")
            s.shutdown()
            exit(0)
        }
    }

    /// `--renderbench <instance>`: GPU cost of presenting the guest frame at window sizes.
    static func renderBench(_ name: String) {
        Task { @MainActor in
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let s = try? GameSession(instance: inst) else { print("no instance"); exit(2) }
            try? await Task.sleep(for: .seconds(2))
            let sizes: [(String, CGSize)] = [("窗口 1280x720 @2x", CGSize(width: 2560, height: 1440)),
                                             ("14寸全屏 3024x1964", CGSize(width: 3024, height: 1964)),
                                             ("16寸全屏 3456x2234", CGSize(width: 3456, height: 2234)),
                                             ("5K 全屏 5120x2880", CGSize(width: 5120, height: 2880)),
                                             ("6K 全屏 6016x3384", CGSize(width: 6016, height: 3384))]
            for (label, sz) in sizes {
                let a = s.renderer.benchmark(size: sz, tiledCopy: false, frames: 120)
                let b = s.renderer.benchmark(size: sz, tiledCopy: true, frames: 120)
                print(String(format: "%@  当前做法 %.2f ms/帧  纹理拷贝 %.2f ms/帧", label, a, b))
            }
            s.shutdown()
            exit(0)
        }
    }

    private static func finish(_ ok: Bool) {
        print(ok ? "ALL PASSED" : "SOME CHECKS FAILED")
        exit(ok ? 0 : 1)
    }
}
