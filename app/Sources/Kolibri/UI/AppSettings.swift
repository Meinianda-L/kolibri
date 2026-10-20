import AppKit
import Carbon.HIToolbox
import SwiftUI
import KolibriCore

/// User preferences (UserDefaults). Keys are shared by @AppStorage views and
/// the non-view code that reads them.
enum Pref {
    /// Host display refresh cap; 0 = follow the screen (ProMotion 120).
    static let maxFPS = "maxFPS"
    /// 后台自动降帧: refresh while the window is not focused; 0 = off.
    static let backgroundFPS = "backgroundFPS"
    /// Pause the VM while its window is minimized.
    static let pauseWhenMinimized = "pauseWhenMinimized"
    static let recordCodec = "recordCodec"
    static let recordAudio = "recordAudio"
    /// 录制/回放时显示点击位置.
    static let showTouches = "showTouches"
    static let screenshotToClipboard = "screenshotToClipboard"
    /// 老板键 ⌃⌥P hides/shows every Kolibri window.
    static let bossKey = "bossKey"
    /// 键鼠浮窗 › 操作控制 › X/Y 轴灵敏度修正.
    static let aimSensX = "aimSensX"
    static let aimSensY = "aimSensY"

    static func register() {
        migrateFromVoltPlay()
        UserDefaults.standard.register(defaults: [
            maxFPS: 0, backgroundFPS: 30, pauseWhenMinimized: false,
            recordCodec: ScreenRecorder.Codec.hevc.rawValue, recordAudio: true,
            showTouches: true, screenshotToClipboard: true, bossKey: true, aimSensX: 1.0, aimSensY: 1.0,
        ])
    }

    static var d: UserDefaults { .standard }

    /// The app was called VoltPlay (bundle id dev.voltplay.app) before Kolibri: carry its
    /// settings and toolbar layout over once, so the rename does not reset anything.
    private static func migrateFromVoltPlay() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "migratedFromVoltPlay") else { return }
        if let old = ud.persistentDomain(forName: "dev.voltplay.app") {
            for (k, v) in old where ud.object(forKey: k) == nil { ud.set(v, forKey: k) }
        }
        ud.set(true, forKey: "migratedFromVoltPlay")
    }
}

struct SettingsView: View {
    @AppStorage(Pref.maxFPS) private var maxFPS = 0
    @AppStorage(Pref.backgroundFPS) private var backgroundFPS = 30
    @AppStorage(Pref.pauseWhenMinimized) private var pauseWhenMinimized = false
    @AppStorage(Pref.recordCodec) private var recordCodec = ScreenRecorder.Codec.hevc.rawValue
    @AppStorage(Pref.recordAudio) private var recordAudio = true
    @AppStorage(Pref.showTouches) private var showTouches = true
    @AppStorage(Pref.screenshotToClipboard) private var screenshotToClipboard = true
    @AppStorage(Pref.bossKey) private var bossKey = true
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        TabView {
            Form {
                Picker(L("语言") + " / Language", selection: $language) {
                    Text(L("跟随系统")).tag(AppLanguage.system.rawValue)
                    Text("中文").tag(AppLanguage.zh.rawValue)
                    Text("English").tag(AppLanguage.en.rawValue)
                }
                Picker(L("画面刷新上限"), selection: $maxFPS) {
                    Text(L("跟随屏幕（最高 120）")).tag(0)
                    ForEach([60, 90, 120, 144], id: \.self) { Text("\($0) Hz").tag($0) }
                }
                Picker(L("后台自动降帧"), selection: $backgroundFPS) {
                    Text(L("关闭")).tag(0)
                    ForEach([10, 20, 30], id: \.self) { Text(L("失去焦点时降到 \($0) 帧")).tag($0) }
                }
                Toggle(L("窗口最小化时暂停安卓"), isOn: $pauseWhenMinimized)
                Text(L("游戏内帧率上限（120 帧解锁）和机型在实例的「机型与帧率」里设置。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label(L("性能"), systemImage: "speedometer") }

            Form {
                Picker(L("录屏编码"), selection: $recordCodec) {
                    ForEach(ScreenRecorder.Codec.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(L("录屏包含游戏声音"), isOn: $recordAudio)
                Toggle(L("截图同时复制到剪贴板"), isOn: $screenshotToClipboard)
                Toggle(L("操作录制/回放时显示点击位置"), isOn: $showTouches)
                Text(L("截图和录屏保存在「图片/Kolibri」与「影片/Kolibri」。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label(L("截图与录制"), systemImage: "record.circle") }

            Form {
                Toggle(L("老板键 ⌃⌥P（一键隐藏/显示所有窗口）"), isOn: $bossKey)
                    .onChange(of: bossKey) { _, on in BossKey.shared.setEnabled(on) }
            }
            .tabItem { Label(L("其他"), systemImage: "gearshape") }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 300)
    }
}

/// System-wide ⌃⌥P via Carbon hot keys (works while another app is in front).
final class BossKey {
    static let shared = BossKey()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func setEnabled(_ on: Bool) {
        if on, ref == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    if NSApp.isHidden { NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true) } else { NSApp.hide(nil) }
                }
                return noErr
            }, 1, &spec, nil, &handler)
            let id = EventHotKeyID(signature: OSType(0x564F_4C54), id: 1) // 'VOLT'
            RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        } else if !on, let r = ref {
            UnregisterEventHotKey(r)
            if let handler { RemoveEventHandler(handler) }
            ref = nil
            handler = nil
        }
    }
}
