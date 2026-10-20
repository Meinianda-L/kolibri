import SwiftUI
import UniformTypeIdentifiers
import KolibriCore

/// 操作录制列表: run / loop / speed, rename, duplicate, merge, import, export, delete.
struct RecordingsView: View {
    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RecordingStore.Item] = []
    @State private var selection = Set<URL>()
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("操作录制")).font(.title3.bold())
                Spacer()
                Button {
                    dismiss()
                    session.startOperationRecording()
                } label: { Label(L("开始录制"), systemImage: "record.circle") }
                .disabled(session.opState != .idle)
            }
            .padding()
            Table(items, selection: $selection) {
                TableColumn(L("名称")) { i in Text(i.recording.name) }
                TableColumn(L("游戏")) { i in Text(i.recording.package ?? "—").foregroundStyle(.secondary) }
                TableColumn(L("分辨率")) { i in Text("\(i.recording.width)×\(i.recording.height)").monospacedDigit() }.width(90)
                TableColumn(L("时长")) { i in Text(clock(i.recording.duration)).monospacedDigit() }.width(70)
                TableColumn(L("创建时间")) { i in Text(i.recording.createdAt, format: .dateTime.month().day().hour().minute()) }.width(110)
            }
            .contextMenu(forSelectionType: URL.self) { sel in
                if sel.count == 1, let i = item(sel.first) {
                    Button(L("执行")) { run(i) }
                    Button(L("复制")) { duplicate(i) }
                    Button(L("导出…")) { export(i) }
                }
                if sel.count > 1 { Button(L("合并为新录制")) { merge(sel) } }
                Button(L("删除"), role: .destructive) { selection = sel; confirmDelete = true }
            } primaryAction: { sel in
                if let i = item(sel.first) { run(i) }
            }
            if selection.count == 1, let i = item(selection.first) {
                PlaybackOptions(item: i) { reload() }.id(i.url).padding(.horizontal).padding(.top, 8)
            }
            HStack {
                Button(L("导入…"), action: importFile)
                Button(L("合并")) { merge(selection) }.disabled(selection.count < 2)
                Button(L("删除"), role: .destructive) { confirmDelete = true }.disabled(selection.isEmpty)
                Spacer()
                Text(L("双击执行 · 录制时不要输入密码等敏感信息")).font(.caption).foregroundStyle(.secondary)
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("执行")) { if let i = item(selection.first) { run(i) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.count != 1 || session.opState != .idle)
            }
            .padding()
        }
        .frame(width: 720, height: 460)
        .onAppear(perform: reload)
        .confirmationDialog(L("删除选中的 \(selection.count) 个录制？"), isPresented: $confirmDelete) {
            Button(L("删除"), role: .destructive) {
                items.filter { selection.contains($0.url) }.forEach(RecordingStore.delete)
                selection = []
                reload()
            }
        }
    }

    private func item(_ url: URL?) -> RecordingStore.Item? { items.first { $0.url == url } }

    private func reload() { items = RecordingStore.list() }

    private func run(_ i: RecordingStore.Item) {
        dismiss()
        session.play(i.recording)
    }

    private func duplicate(_ i: RecordingStore.Item) {
        var r = i.recording
        r.name += L(" 副本")
        r.createdAt = Date()
        try? RecordingStore.save(r)
        reload()
    }

    private func merge(_ sel: Set<URL>) {
        let parts = items.filter { sel.contains($0.url) }.sorted { $0.recording.createdAt < $1.recording.createdAt }.map(\.recording)
        guard parts.count > 1, let m = OperationRecording.merge(parts, name: L("合并 ") + parts.map(\.name).joined(separator: "+")) else { return }
        try? RecordingStore.save(m)
        reload()
    }

    private func export(_ i: RecordingStore.Item) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = i.url.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { try? RecordingStore.save(i.recording, to: url) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vprec") ?? .json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for u in panel.urls { _ = try? RecordingStore.importFile(u) }
        reload()
    }
}

/// Per-recording playback settings, saved back into the file.
private struct PlaybackOptions: View {
    let item: RecordingStore.Item
    let changed: () -> Void
    @State private var r: OperationRecording

    init(item: RecordingStore.Item, changed: @escaping () -> Void) {
        self.item = item
        self.changed = changed
        _r = State(initialValue: item.recording)
    }

    var body: some View {
        HStack(spacing: 16) {
            TextField(L("名称"), text: $r.name).frame(width: 160)
            Stepper(r.repeatTimes == 0 ? L("循环：无限") : L("执行 \(r.repeatTimes) 次"), value: $r.repeatTimes, in: 0...999)
            Stepper(L("间隔 \(String(format: "%.1f", r.repeatDelay)) 秒"), value: $r.repeatDelay, in: 0...600, step: 0.5)
            Picker(L("速度"), selection: $r.speed) {
                ForEach([0.5, 1, 1.5, 2, 3, 5], id: \.self) { Text("\(String(format: "%g", $0))×").tag($0) }
            }
            .frame(width: 110)
        }
        .onChange(of: r) { _, new in
            try? RecordingStore.save(new, to: item.url)
            changed()
        }
    }
}
