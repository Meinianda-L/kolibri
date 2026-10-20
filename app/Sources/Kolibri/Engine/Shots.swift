import AppKit
import SwiftUI
import KolibriCore

/// `--shots <instance> <dir> <frame.png> <zh|en>`: README screenshots of each feature, in Chinese
/// and English. Real AppKit windows placed off screen and captured with cacheDisplay (no
/// screen-recording permission needed); the game picture comes from `frame.png`.
@MainActor
enum Shots {
    static func run(_ name: String, dir: String, frame: String, lang only: String) {
        Task { @MainActor in
            guard let inst = try? await KolibriCtl.list().first(where: { $0.name == name && $0.running }),
                  let session = try? GameSession(instance: inst),
                  let frameImage = NSImage(contentsOfFile: frame) else { print("need a running instance and a frame png"); exit(2) }
            // Headless runs have no bundle icon; the device placeholder shows the app icon.
            let icns = KolibriCtl.scriptURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("app/Resources/AppIcon.icns")
            if let icon = NSImage(contentsOf: icns) { NSApp.applicationIconImage = icon }
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            for lang in [AppLanguage.zh, .en] where lang.rawValue == only {
                UserDefaults.standard.set(lang.rawValue, forKey: AppLanguage.defaultsKey)
                let tag = lang.rawValue
                await capture(ManagerView(), CGSize(width: 980, height: 340), "Kolibri", out, "devices-\(tag).png", wait: 2.5)
                await capture(CreateInstanceSheet { _ in }, CGSize(width: 460, height: 420), L("新建设备"), out, "new-device-\(tag).png")
                for pane in EditDeviceSheet.Pane.allCases {
                    await capture(EditDeviceSheet(inst: inst, pane: pane) {}, CGSize(width: 520, height: 480),
                                  L("编辑设备"), out, "edit-\(pane.id(lang: .en))-\(tag).png", wait: 2.5)
                }
                await capture(SettingsView(), CGSize(width: 560, height: 300), L("设置"), out, "settings-\(tag).png")

                var demo = Keymap(name: L("自定义方案"), controls: [
                    ControlKind.dpad.make(at: NPoint(0.14, 0.72), pad: false),
                    ControlKind.crosshair.make(at: NPoint(0.62, 0.45), pad: false),
                    ControlKind.fire.make(at: NPoint(0.86, 0.66), pad: false),
                    ControlKind.spell.make(at: NPoint(0.74, 0.80), pad: false),
                    ControlKind.click.make(at: NPoint(0.93, 0.48), pad: false),
                    .button(binding: .key(49), at: NPoint(0.80, 0.30), mode: .hold),
                ], aimToggle: .key(50))
                demo.setExtra(5, ControlExtra(note: L("跳")))
                let game = { (v: AnyView) in
                    AnyView(ZStack { Image(nsImage: frameImage).resizable().aspectRatio(contentMode: .fit); v }.background(Color.black))
                }
                let size = CGSize(width: 1280, height: 720)
                await capture(game(AnyView(KeymapEditor(session: session, kind: .keyboard,
                                                       preview: .init(draft: demo, menuAt: CGPoint(x: 420, y: 260))))),
                              size, L("键位编辑"), out, "keymap-editor-\(tag).png")
                await capture(game(AnyView(KeymapEditor(session: session, kind: .keyboard,
                                                       preview: .init(draft: demo, focused: 3, settingsFor: 3)))),
                              size, L("键位编辑"), out, "keymap-settings-\(tag).png")
                await capture(game(AnyView(KeymapHints(keymap: demo, width: inst.width, height: inst.height))),
                              size, inst.name, out, "key-hints-\(tag).png")
                await capture(KeymapPopover(session: session, kind: .keyboard, close: {}).fixedSize(),
                              CGSize(width: 320, height: 380), L("键位方案"), out, "keymap-popover-\(tag).png")
            }
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
            session.shutdown()
            exit(0)
        }
    }

    private static func capture<V: View>(_ view: V, _ size: CGSize, _ title: String, _ dir: URL, _ file: String,
                                         wait: Double = 1.2) async {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))   // off screen: nothing flashes on the user's display
        w.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(wait))
        guard let frameView = w.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent(file))
            print("wrote \(file)")
        }
        w.orderOut(nil)
        w.contentView = nil   // a live hosting view keeps updating its graph
        w.close()
    }
}

private extension EditDeviceSheet.Pane {
    func id(lang: AppLanguage) -> String {
        switch self {
        case .performance: return "performance"
        case .display: return "display"
        case .model: return "model"
        case .identity: return "identity"
        case .storage: return "storage"
        }
    }
}
