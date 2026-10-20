import SwiftUI
import KolibriCore

/// 设备管理: one row per device (last-screen thumbnail, name, state, specs) with start /
/// enter / stop and a more menu. New devices come from the toolbar.
struct ManagerView: View {
    static var autoOpened = false
    @Environment(\.openWindow) private var openWindow
    @State private var instances: [InstanceInfo] = []
    /// Device name -> what is running on it right now ("启动中…").
    @State private var busy: [String: String] = [:]
    @State private var error: String?
    @State private var showCreate = false
    @State private var editing: InstanceInfo?
    @State private var confirmReset: InstanceInfo?
    @State private var confirmDelete: InstanceInfo?
    /// Android engine / system image still to download (first launch).
    @State private var setup: SetupSheet.Check?

    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if instances.isEmpty {
                ContentUnavailableView {
                    Label { Text(L("还没有设备")) } icon: { Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64) }
                } description: {
                    Text(L("新建一台安卓设备，就可以下载和玩游戏了。"))
                } actions: {
                    Button(L("新建设备")) { showCreate = true }.buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(instances) { row($0) }
                    }
                    .padding(16)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(2)
                    Spacer()
                    Button { self.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(10)
                .background(.bar)
            }
        }
        .navigationTitle("Kolibri")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showCreate = true } label: { Label(L("新建设备"), systemImage: "plus") }
                    .help(L("新建设备"))
            }
        }
        .task {
            // kolibrictl runs on the system Python, which comes with Apple's Command Line Tools.
            let pythons = ["/Library/Developer/CommandLineTools/usr/bin/python3",
                           "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
            if !pythons.contains(where: FileManager.default.fileExists(atPath:)) {
                error = L("需要先安装 Apple 命令行工具（提供 Python），安装完成后重新打开 Kolibri。")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
                p.arguments = ["--install"]
                try? p.run()
                return
            }
            if let out = try? await KolibriCtl.run(["setup", "--check", "--json"]),
               let c = try? JSONDecoder().decode(SetupSheet.Check.self, from: Data(out.utf8)), !c.ready {
                setup = c
            }
            await refresh()
            // `Kolibri --open <name>` jumps straight into a running device.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), i + 1 < args.count, !ManagerView.autoOpened {
                ManagerView.autoOpened = true
                openWindow(id: "game", value: args[i + 1])
            }
        }
        .onReceive(timer) { _ in Task { await refresh() } }
        .sheet(isPresented: $showCreate) {
            CreateInstanceSheet { name in
                // A new device is only a config until it is provisioned (system, launcher, store).
                await refresh()
                if let inst = instances.first(where: { $0.name == name }) {
                    act(inst, ["provision", name], label: L("初始化中…"))
                }
            }
        }
        .sheet(isPresented: Binding(get: { setup != nil }, set: { _ in })) {
            if let setup { SetupSheet(check: setup) { self.setup = nil } }
        }
        .sheet(item: $editing) { EditDeviceSheet(inst: $0) { await refresh() } }
        .confirmationDialog(L("恢复出厂设置？"), isPresented: Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } }),
                            presenting: confirmReset) { inst in
            Button(L("恢复出厂"), role: .destructive) { act(inst, ["reset", inst.name], label: L("恢复出厂中…")) }
        } message: { inst in
            Text(L("“\(inst.name)”里的应用和数据会全部清除，机型、分辨率和性能设置保留。"))
        }
        .confirmationDialog(L("删除设备？"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { inst in
            Button(L("删除"), role: .destructive) { act(inst, ["delete", inst.name], label: L("删除中…")) }
        } message: { inst in
            Text(L("“\(inst.name)”和其中的所有数据都会被删除，无法恢复。"))
        }
    }

    private var subtitle: String {
        if instances.isEmpty { return "" }
        let running = instances.filter(\.running).count
        return running > 0 ? L("\(instances.count) 台设备 · \(running) 台运行中") : L("\(instances.count) 台设备")
    }

    // MARK: Row

    private func row(_ inst: InstanceInfo) -> some View {
        DeviceCard(inst: inst, busy: busy[inst.name],
                   primary: { inst.running ? openWindow(id: "game", value: inst.name) : start(inst) },
                   stop: { act(inst, ["stop", inst.name, "--no-wait"], label: L("停止中…")) },
                   edit: { editing = inst }) {
            menuItems(inst)
        }
    }

    private func start(_ inst: InstanceInfo) {
        act(inst, inst.provisioned ? ["start", inst.name] : ["provision", inst.name],
            label: inst.provisioned ? L("启动中…") : L("初始化中…")) {
            openWindow(id: "game", value: inst.name)
        }
    }

    @ViewBuilder
    private func menuItems(_ inst: InstanceInfo) -> some View {
        Button(L("编辑设备…")) { editing = inst }
        Button(L("复制设备")) { act(inst, ["clone", inst.name, cloneName(inst.name)], label: L("复制中…")) }
            .disabled(inst.running)
        Divider()
        Button(L("恢复出厂…")) { confirmReset = inst }
        Button(L("删除…")) { confirmDelete = inst }
            .disabled(inst.running)
    }

    /// a16b -> a16b-2 (or the next free number).
    private func cloneName(_ base: String) -> String {
        let names = Set(instances.map(\.name))
        var n = 2
        while names.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func act(_ inst: InstanceInfo, _ args: [String], label: String, then: (() -> Void)? = nil) {
        busy[inst.name] = label
        Task {
            do { try await KolibriCtl.run(args); error = nil; then?() }
            catch { self.error = "\(inst.name)：\(error.localizedDescription)" }
            busy[inst.name] = nil
            await refresh()
        }
    }

    private func refresh() async {
        do { instances = try await KolibriCtl.list() } catch { self.error = error.localizedDescription }
    }
}

/// One device: last-screen thumbnail (click to start / enter), name and phone
/// model, state, specs, and the actions on the right.
private struct DeviceCard<Menu: View>: View {
    let inst: InstanceInfo
    let busy: String?
    let primary: () -> Void
    let stop: () -> Void
    let edit: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hover = false

    private var state: (String, Color) {
        if let busy { return (busy, .orange) }
        if inst.running { return (L("运行中"), .green) }
        if inst.stopping == true { return (L("正在保存…"), .orange) }
        return (inst.provisioned ? L("未启动") : L("未初始化"), .secondary)
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: primary) {
                Thumbnail(name: inst.name, running: inst.running, hover: hover && busy == nil)
            }
            .buttonStyle(.plain)
            .disabled(busy != nil)
            .help(inst.running ? L("进入") : L("启动"))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(inst.device_name?.isEmpty == false ? inst.device_name! : inst.name)
                        .font(.system(size: 15, weight: .semibold))
                    StatePill(text: state.0, color: state.1, spinning: busy != nil || inst.stopping == true)
                }
                Text(DeviceProfiles.title(inst.profile) + (inst.device_name?.isEmpty == false ? " · \(inst.name)" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Spec(icon: "cpu", text: L("\(inst.cores) 核"))
                    Spec(icon: "memorychip", text: "\(inst.ram_mb / 1024) GB")
                    Spec(icon: "rectangle", text: "\(inst.width)×\(inst.height)")
                    Spec(icon: "speedometer", text: "\(inst.refresh_hz) Hz")
                    if inst.hasRoot { Spec(icon: "number", text: "root") }
                }
            }
            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if busy == nil && inst.stopping != true {
                    Button(action: primary) {
                        Label(inst.running ? L("进入") : L("启动"), systemImage: inst.running ? "arrow.up.forward.app" : "play.fill")
                            .frame(minWidth: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if inst.running {
                        IconButton(symbol: "stop.fill", help: L("停止"), action: stop)
                    }
                }
                IconButton(symbol: "slider.horizontal.3", help: L("编辑设备"), action: edit)
                    .disabled(busy != nil)
                SwiftUI.Menu { menu() } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("更多"))
                    .disabled(busy != nil)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(hover ? 0.06 : 0)))
                .shadow(color: .black.opacity(hover ? 0.10 : 0.04), radius: hover ? 6 : 2, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if busy == nil { primary() } }
        .contextMenu { menu() }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

private struct StatePill: View {
    let text: String
    let color: Color
    var spinning = false

    var body: some View {
        HStack(spacing: 5) {
            if spinning { ProgressView().controlSize(.mini) } else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.caption.weight(.medium))
        }
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill((color == .secondary ? Color.gray : color).opacity(0.14)))
    }
}

private struct Spec: View {
    let icon: String
    let text: String

    var body: some View {
        Label { Text(text) } icon: { Image(systemName: icon).font(.system(size: 11)) }
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 20) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(help)
    }
}

/// The device's last screen (saved by `kolibrictl stop`), or the app icon before it has one.
/// Hovering shows what a click does.
private struct Thumbnail: View {
    let name: String
    var running = false
    var hover = false

    var body: some View {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kolibri/avd/\(name).avd/thumbnail.png")
        ZStack {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.93, green: 0.97, blue: 0.97), Color(red: 0.80, green: 0.91, blue: 0.93)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            }
            if hover {
                Color.black.opacity(0.35)
                Image(systemName: running ? "arrow.up.forward.app.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 192, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// 新建设备. Provisioning (system, launcher, store) runs afterwards in the device list.
struct CreateInstanceSheet: View {
    var onCreated: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "phone1"
    @State private var resolution = "1600x900"
    @State private var refresh = 120
    @State private var cores = 4
    @State private var ramGB = 4
    @State private var profile = "flagship-120"
    @State private var root = false
    @State private var error: String?
    @State private var working = false

    private var validName: Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("名称"), text: $name, prompt: Text(L("字母、数字、- 或 _")))
                    Picker(L("机型"), selection: $profile) {
                        ForEach(DeviceProfiles.presets) { Text($0.title).tag($0.name) }
                    }
                }
                Section {
                    Picker(L("分辨率"), selection: $resolution) {
                        ForEach(["1280x720", "1600x900", "1920x1080", "2560x1440"], id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")) }
                    }
                    Picker(L("刷新率"), selection: $refresh) { Text("60 Hz").tag(60); Text("90 Hz").tag(90); Text("120 Hz").tag(120) }
                    Picker("CPU", selection: $cores) { ForEach([2, 3, 4, 6, 8], id: \.self) { Text(L("\($0) 核")).tag($0) } }
                    Picker(L("内存"), selection: $ramGB) { ForEach([2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0) GB").tag($0) } }
                }
                Section {
                    Toggle(L("允许应用获取 root"), isOn: $root)
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            HStack {
                if let error { Text(error).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("创建")) { create() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !validName)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460, height: 420)
    }

    private func create() {
        working = true
        Task {
            do {
                try await KolibriCtl.run(["create", name, "--resolution", resolution, "--refresh", "\(refresh)",
                                          "--cores", "\(cores)", "--ram", "\(ramGB * 1024)", "--profile", profile]
                                         + (root ? ["--root"] : []))
                dismiss()
                await onCreated(name)
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

enum DeviceProfiles {
    static var names: [String] { presets.map(\.name) }
}
