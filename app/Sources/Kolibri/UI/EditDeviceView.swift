import SwiftUI
import KolibriCore

/// A phone preset from engine/profiles (`name` is the file stem).
struct PhonePreset: Identifiable, Hashable {
    let name: String
    let title: String
    let gpu: String?
    var id: String { name }
}

extension DeviceProfiles {
    static var presets: [PhonePreset] {
        let dir = KolibriCtl.scriptURL.deletingLastPathComponent().appendingPathComponent("profiles")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let all: [PhonePreset] = files.filter { $0.hasSuffix(".json") }.compactMap { f in
            let name = String(f.dropLast(5))
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(f)),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let title = (AppLanguage.resolved == .en ? d["title_en"] as? String : nil) ?? d["title"] as? String ?? name
            return PhonePreset(name: name, title: title, gpu: d["gpu_renderer"] as? String)
        }
        // "stock" (no disguise) goes last.
        return all.sorted { ($0.name == "stock" ? 1 : 0, $0.title) < ($1.name == "stock" ? 1 : 0, $1.title) }
    }

    static func title(_ name: String) -> String {
        name == "custom" ? L("自定义机型") : presets.first { $0.name == name }?.title ?? name
    }
}

/// GPU names games see; games pick quality and frame-rate tiers by them.
private let gpuPresets = ["Adreno (TM) 750", "Adreno (TM) 740", "Adreno (TM) 730", "Adreno (TM) 710",
                          "Adreno (TM) 660", "Adreno (TM) 650", "Adreno (TM) 640",
                          "Mali-G720-Immortalis MC12", "Mali-G715", "Maleoon 910"]
private let resolutionPresets = [(1280, 720), (1600, 900), (1920, 1080), (2560, 1440), (3200, 1800)]
private let dpiPresets = [240, 280, 320, 360, 400, 480]

/// 编辑设备: performance, display, phone model / GPU and identity of one device.
/// Applying restarts the device when needed (kolibrictl edit decides) and re-saves its snapshot.
struct EditDeviceSheet: View {
    let inst: InstanceInfo
    var onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss

    enum Pane: String, CaseIterable, Identifiable {
        case performance = "性能", display = "显示", model = "机型", identity = "设备信息", storage = "存储"
        var id: String { rawValue }
    }

    @State private var pane = Pane.performance
    @State private var cores: Int
    @State private var ramGB: Int
    @State private var resolution: String       // "WxH" or "custom"
    @State private var width: Int
    @State private var height: Int
    @State private var dpi: Int
    @State private var refresh: Int
    @State private var profile: String
    @State private var custom: [String: String]
    @State private var gpu: String              // "" follows the phone model, "custom" uses customGPU
    @State private var customGPU: String
    @State private var deviceName: String
    @State private var phone: String
    @State private var root: Bool
    @State private var androidID: String?
    @State private var confirmNewID = false
    @State private var storage: StorageInfo?
    @State private var dataGB = 0
    @State private var confirmClean = false
    @State private var notice: String?
    @State private var working: String?
    @State private var error: String?

    init(inst: InstanceInfo, pane: Pane = .performance, onDone: @escaping () async -> Void) {
        self.inst = inst
        self.onDone = onDone
        _pane = State(initialValue: pane)
        _cores = State(initialValue: inst.cores)
        _ramGB = State(initialValue: max(1, inst.ram_mb / 1024))
        let key = "\(inst.width)x\(inst.height)"
        _resolution = State(initialValue: resolutionPresets.contains { "\($0.0)x\($0.1)" == key } ? key : "custom")
        _width = State(initialValue: inst.width)
        _height = State(initialValue: inst.height)
        _dpi = State(initialValue: inst.dpi)
        _refresh = State(initialValue: inst.refresh_hz)
        _profile = State(initialValue: inst.profile)
        _custom = State(initialValue: inst.custom_profile ?? ["brand": "Xiaomi", "manufacturer": "Xiaomi", "model": "",
                                                               "device": "", "soc_manufacturer": "QTI", "soc_model": "SM8650"])
        let g = inst.gpu_renderer ?? ""
        _gpu = State(initialValue: g.isEmpty ? "" : gpuPresets.contains(g) ? g : "custom")
        _customGPU = State(initialValue: gpuPresets.contains(g) ? "" : g)
        _deviceName = State(initialValue: inst.device_name ?? "")
        _phone = State(initialValue: inst.phone_number ?? "")
        _root = State(initialValue: inst.hasRoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text(L($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)

            Form {
                switch pane {
                case .performance: performance
                case .display: display
                case .model: model
                case .identity: identity
                case .storage: storagePane
                }
            }
            .formStyle(.grouped)
            .disabled(working != nil)

            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 520, height: 480)
        .task { await loadAndroidID() }
        .task { await loadStorage() }
        .confirmationDialog(L("重新生成设备 ID？"), isPresented: $confirmNewID) {
            Button(L("重新生成"), role: .destructive) { apply(["reset-id", inst.name], label: L("正在生成新的设备 ID…")) }
        } message: {
            Text(L("所有应用会把这台设备当成一台新手机，部分游戏需要重新登录。"))
        }
        .confirmationDialog(L("清理磁盘？"), isPresented: $confirmClean) {
            Button(L("清理")) { storageAction(["clean", inst.name], label: L("正在清理磁盘…")) }
        } message: {
            Text(inst.running ? L("设备会先停止。清理会删除快照并压缩磁盘文件，应用和数据不受影响；下次启动是完整开机，约一分钟。")
                              : L("清理会删除快照并压缩磁盘文件，应用和数据不受影响；下次启动是完整开机，约一分钟。"))
        }
    }

    // MARK: Panes

    private var performance: some View {
        Section {
            Picker("CPU", selection: $cores) {
                ForEach([2, 3, 4, 6, 8], id: \.self) { Text(L("\($0) 核")).tag($0) }
            }
            Picker(L("内存"), selection: $ramGB) {
                ForEach([2, 3, 4, 6, 8, 12], id: \.self) { Text("\($0) GB").tag($0) }
            }
        }
    }

    private var display: some View {
        Section {
            Picker(L("分辨率"), selection: $resolution) {
                ForEach(resolutionPresets, id: \.0) { Text("\($0.0) × \($0.1)").tag("\($0.0)x\($0.1)") }
                Text(L("自定义")).tag("custom")
            }
            if resolution == "custom" {
                HStack {
                    TextField(L("宽"), value: $width, format: .number.grouping(.never))
                    Text("×").foregroundStyle(.secondary)
                    TextField(L("高"), value: $height, format: .number.grouping(.never))
                }
            }
            Picker("DPI", selection: $dpi) {
                ForEach(Array(Set(dpiPresets + [inst.dpi])).sorted(), id: \.self) { Text("\($0)").tag($0) }
            }
            Picker(L("刷新率"), selection: $refresh) {
                ForEach([60, 90, 120], id: \.self) { Text("\($0) Hz").tag($0) }
            }
        }
    }

    private var model: some View {
        Group {
            Section {
                Picker(L("机型"), selection: $profile) {
                    ForEach(DeviceProfiles.presets) { Text($0.title).tag($0.name) }
                    Divider()
                    Text(L("自定义机型")).tag("custom")
                }
                if profile == "custom" {
                    TextField(L("品牌"), text: binding("brand"))
                    TextField(L("型号"), text: binding("model"), prompt: Text(L("例如 23127PN0CC")))
                    TextField(L("设备代号"), text: binding("device"), prompt: Text(L("例如 houji")))
                    TextField(L("芯片型号"), text: binding("soc_model"), prompt: Text(L("例如 SM8650")))
                }
            }
            Section {
                Picker(L("GPU 型号"), selection: $gpu) {
                    Text(L("跟随机型（\(presetGPU)）")).tag("")
                    Divider()
                    ForEach(gpuPresets, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text(L("自定义")).tag("custom")
                }
                if gpu == "custom" {
                    TextField(L("GPU 名称"), text: $customGPU, prompt: Text(L("例如 Adreno (TM) 640")))
                }
            } footer: {
                Text(L("游戏会按 GPU 型号决定可选画质和帧率档位。")).foregroundStyle(.secondary)
            }
        }
    }

    private var identity: some View {
        Group {
            Section {
                TextField(L("设备名称"), text: $deviceName, prompt: Text(DeviceProfiles.title(profile)))
                HStack {
                    TextField(L("手机号"), text: $phone, prompt: Text(L("未设置")))
                    Button(L("随机")) { phone = Self.randomPhone() }
                }
                Toggle(L("允许应用获取 root"), isOn: $root)
            }
            Section {
                LabeledContent("Android ID") {
                    Text(androidID ?? (inst.running ? L("读取中…") : L("启动后显示")))
                        .foregroundStyle(.secondary).textSelection(.enabled).monospaced()
                }
                Button(L("重新生成设备 ID…")) { confirmNewID = true }
                    .disabled(!inst.running)
            } footer: {
                Text(L("游戏靠 Android ID 识别设备。安卓 10 起应用读不到 IMEI 和 MAC 地址，修改它们没有效果。"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storagePane: some View {
        Group {
            Section {
                LabeledContent(L("占用空间")) {
                    Text(storage.map { gb($0.on_disk) } ?? L("计算中…")).foregroundStyle(.secondary)
                }
                LabeledContent(L("存储位置")) {
                    HStack {
                        Text(storage.map { ($0.dir as NSString).abbreviatingWithTildeInPath } ?? "")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button { if let d = storage?.dir { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d)]) } } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless).help(L("在访达中显示"))
                    }
                }
                HStack {
                    Spacer()
                    if storage?.custom_dir == true {
                        Button(L("恢复默认位置")) { storageAction(["move", inst.name, "default"], label: L("正在移动设备文件…")) }
                    }
                    Button(L("更改位置…")) { chooseFolder() }
                }
                .disabled(inst.running)
            } footer: {
                Text(storage.map { L("所在磁盘剩余 \(gb($0.free))。可以放到外置硬盘，使用时需接上。") } ?? "")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(L("数据盘"), selection: $dataGB) {
                    ForEach(dataSizes, id: \.self) { Text("\($0) GB").tag($0) }
                }
                if let s = storage, dataGB > s.data_gb {
                    HStack {
                        Spacer()
                        Button(L("扩容到 \(dataGB) GB")) { storageAction(["resize", inst.name, "\(dataGB)"], label: L("正在扩容…")) }
                    }
                }
            } footer: {
                Text(L("数据盘用多少占多少，不会预先占满 Mac 的空间。已有数据的设备在线扩容有上限，恢复出厂后按新容量完整生效。"))
                    .foregroundStyle(.secondary)
            }
            .disabled(inst.running)
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("磁盘清理"))
                        Text(L("删除快照、压缩磁盘文件，不影响应用和数据")).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("清理…")) { confirmClean = true }
                }
            } footer: {
                if inst.running { Text(L("停止设备后才能扩容或更改位置。")).foregroundStyle(.secondary) }
            }
        }
    }

    private var dataSizes: [Int] {
        let cur = storage?.data_gb ?? 16
        return Array(Set([cur, 32, 64, 128, 256].filter { $0 >= cur })).sorted()
    }

    private func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("移到这里")
        panel.message = L("选择存放“\(inst.name)”磁盘文件的文件夹")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storageAction(["move", inst.name, url.path], label: L("正在移动设备文件…"))
    }

    /// Storage changes apply right away (not on 保存) and keep the sheet open.
    private func storageAction(_ args: [String], label: String) {
        working = label
        error = nil
        Task {
            do {
                let before = storage?.on_disk
                try await KolibriCtl.run(args)
                await onDone()
                await loadStorage()
                working = nil
                if args.first == "clean", let before, let after = storage?.on_disk {
                    notice = L("清理完成，释放了 \(gb(max(0, before - after)))")
                }
            } catch {
                self.error = error.localizedDescription
                working = nil
            }
        }
    }

    private func loadStorage() async {
        guard let out = try? await KolibriCtl.run(["storage", inst.name, "--json"]),
              let s = try? JSONDecoder().decode(StorageInfo.self, from: Data(out.utf8)) else { return }
        storage = s
        if dataGB == 0 || dataGB < s.data_gb { dataGB = s.data_gb }
    }

    private var footer: some View {
        HStack {
            if let working {
                ProgressView().controlSize(.small)
                Text(working).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(.red).lineLimit(2)
            } else if let notice {
                Text(notice).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working != nil)
            Button(L("保存")) { save() }.keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working != nil || changes.isEmpty)
        }
    }

    // MARK: Model

    private var presetGPU: String {
        DeviceProfiles.presets.first { $0.name == profile }?.gpu ?? custom["gpu_renderer"] ?? "Adreno (TM) 750"
    }

    private func binding(_ key: String) -> SwiftUI.Binding<String> {
        SwiftUI.Binding(get: { custom[key] ?? "" }, set: { custom[key] = $0 })
    }

    private var targetResolution: [Int] {
        if resolution != "custom", let p = resolutionPresets.first(where: { "\($0.0)x\($0.1)" == resolution }) { return [p.0, p.1] }
        return [width, height]
    }

    /// Only what differs from the device as it is now.
    private var changes: [String: Any] {
        var c: [String: Any] = [:]
        if cores != inst.cores { c["cores"] = cores }
        if ramGB * 1024 != inst.ram_mb { c["ram_mb"] = ramGB * 1024 }
        if targetResolution != [inst.width, inst.height] { c["resolution"] = targetResolution }
        if dpi != inst.dpi { c["dpi"] = dpi }
        if refresh != inst.refresh_hz { c["refresh_hz"] = refresh }
        if profile != inst.profile { c["profile"] = profile }
        if profile == "custom" {
            var cp = custom.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            cp["manufacturer"] = cp["brand"]
            cp["product"] = cp["device"]
            if cp != (inst.custom_profile ?? [:]) { c["custom_profile"] = cp }
        }
        let g = gpu == "custom" ? customGPU.trimmingCharacters(in: .whitespaces) : gpu
        if g != (inst.gpu_renderer ?? "") { c["gpu_renderer"] = g }
        let name = deviceName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "'", with: "")
        if name != (inst.device_name ?? "") { c["device_name"] = name }
        let digits = phone.filter(\.isNumber)
        if digits != (inst.phone_number ?? "") { c["phone_number"] = digits }
        if root != inst.hasRoot { c["root"] = root }
        return c
    }

    private func save() {
        let c = changes
        if c["profile"] as? String == "custom", (c["custom_profile"] as? [String: String] ?? inst.custom_profile ?? [:])["model"]?.isEmpty ?? true {
            error = L("自定义机型至少要填型号")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: c),
              let json = String(data: data, encoding: .utf8) else { return }
        apply(["edit", inst.name, "--json", json], label: L("正在应用，设备会重启一次…"))
    }

    private func apply(_ args: [String], label: String) {
        working = label
        error = nil
        Task {
            do {
                try await KolibriCtl.run(args)
                await onDone()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = nil
        }
    }

    private func loadAndroidID() async {
        guard inst.running,
              let out = try? await KolibriCtl.run(["info", inst.name]),
              let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return }
        androidID = (d["android_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A plausible mainland mobile number (13x-19x).
    static func randomPhone() -> String {
        let second = ["3", "5", "7", "8", "9"].randomElement()!
        return "1" + second + (0..<9).map { _ in String(Int.random(in: 0...9)) }.joined()
    }
}

/// `kolibrictl storage <name> --json`.
struct StorageInfo: Decodable {
    var dir: String
    var custom_dir: Bool
    var on_disk: Int64
    var data_gb: Int
    var free: Int64
}
