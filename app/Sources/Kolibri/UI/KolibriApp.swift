import AppKit
import SwiftUI
import KolibriCore

/// Entry point. Test modes (`--selftest`, `--renderbench`, `--uisnap`, `--touchtest`,
/// `--renderload`) run fully headless: no SwiftUI scenes, no windows, no Dock icon.
@main
enum Entry {
    static let testFlags = ["--selftest", "--renderbench", "--uisnap", "--touchtest", "--renderload", "--audiotest", "--framecheck", "--androidkey", "--shots"]

    static func main() {
        let args = CommandLine.arguments
        guard testFlags.contains(where: args.contains) else { KolibriApp.main(); return }
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        // --shots draws real (off-screen) windows, which a prohibited app can't have.
        app.setActivationPolicy(args.contains("--shots") ? .accessory : .prohibited)
        MainActor.assumeIsolated { Headless.start(args) }
        app.run()
    }
}

@MainActor
enum Headless {
    static func start(_ args: [String]) {
        Pref.register()
        func arg(_ flag: String, _ n: Int) -> [String]? {
            guard let i = args.firstIndex(of: flag), i + n < args.count else { return nil }
            return Array(args[(i + 1)...(i + n)])
        }
        if let a = arg("--selftest", 1) { SelfTest.run(a[0]) }
        else if let a = arg("--shots", 4) { Shots.run(a[0], dir: a[1], frame: a[2], lang: a[3]) }
        else if let a = arg("--uisnap", 2) { SelfTest.uiSnap(a[0], dir: a[1]) }
        else if let a = arg("--renderbench", 1) { SelfTest.renderBench(a[0]) }
        else if let a = arg("--touchtest", 2) { SelfTest.touchTest(a[0], scenario: a[1]) }
        else if let a = arg("--androidkey", 2) { SelfTest.androidKey(a[0], key: a[1]) }
        else if let a = arg("--framecheck", 2) { SelfTest.frameCheck(a[0], seconds: Double(a[1]) ?? 20) }
        else if let a = arg("--audiotest", 2) { SelfTest.audioTest(a[0], seconds: Double(a[1]) ?? 10) }
        else if let a = arg("--renderload", 4) { SelfTest.renderLoad(a[0], size: a[1], mode: a[2], seconds: Double(a[3]) ?? 45) }
        else { print("missing arguments"); exit(2) }
    }
}

struct KolibriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// Changing the language rebuilds every window's views (L() reads it when a view is built).
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup("Kolibri", id: "manager") {
            ManagerView()
                .frame(minWidth: 760, minHeight: 460)
                .id(language)
        }
        .windowResizability(.contentMinSize)

        WindowGroup("Kolibri", id: "game", for: String.self) { $name in
            if let name { GameWindowView(instanceName: name).id(language) }
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .defaultSize(width: 1280, height: 760)
        .commands {
            GameCommands()
            ToolbarCommands()
        }

        Settings { SettingsView().id(language) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IOLBF, 0)
        Pref.register()
        BossKey.shared.setEnabled(Pref.d.bool(forKey: Pref.bossKey))
        // SwiftPM executables start as background apps; promote to a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
