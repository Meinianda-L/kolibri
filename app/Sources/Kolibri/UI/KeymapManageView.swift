import SwiftUI
import UniformTypeIdentifiers
import KolibriCore

/// 键鼠方案管理 / 手柄方案管理: scheme list on the left,
/// description on the right, 应用 / 编辑 / 复制 / 重命名 / 导出 / 删除.
struct KeymapManageView: View {
    @ObservedObject var session: GameSession
    @State var kind: SchemeKind
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String] = []
    @State private var selected: String?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    private var pkg: String? { session.foregroundPackage }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind == .keyboard ? L("键鼠方案管理") : L("手柄方案管理")).font(.title3.bold())
                Spacer()
                Picker("", selection: $kind) {
                    ForEach(SchemeKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            .padding()
            Divider()
            HStack(spacing: 0) {
                List(names, id: \.self, selection: $selected) { n in
                    HStack {
                        Text(n)
                        Spacer()
                        if isApplied(n) { Text(L("已应用")).font(.caption).foregroundStyle(Color.accentColor) }
                    }
                }
                .frame(width: 230)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding()
            }
            Divider()
            HStack {
                Button(L("导入…"), action: importScheme)
                Button(L("新建方案")) { dismiss(); session.beginEditing(kind, newScheme: true) }
                Spacer()
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 640, height: 420)
        .onAppear(perform: reload)
        .onChange(of: kind) { _, _ in reload() }
        .alert(L("输入方案名称："), isPresented: $renaming) {
            TextField(L("方案名称"), text: $newName)
            Button(L("确定")) { rename() }
            Button(L("取消"), role: .cancel) {}
        }
        .confirmationDialog(L("确定删除吗？"), isPresented: $confirmDelete) {
            Button(L("删除"), role: .destructive) {
                if let n = selected { KeymapStore.delete(pkg, kind, n) }
                session.reloadSchemes()
                reload()
            }
        } message: { Text(L("删除后将无法恢复。")) }
    }

    @ViewBuilder
    private var detail: some View {
        if let n = selected, let k = KeymapStore.load(pkg, kind, n) {
            VStack(alignment: .leading, spacing: 10) {
                Text(n).font(.title2.bold())
                Group {
                    Text(L("方案类型: 自定义"))
                    Text(L("适用游戏: \(pkg ?? L("全局"))"))
                    Text(L("按键数量: \(k.controls.count)"))
                    if let d = modified(n) { Text(L("更新时间: \(d.formatted(date: .numeric, time: .shortened))")) }
                }
                .foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Button(isApplied(n) ? L("已应用") : L("应用")) { session.selectScheme(kind, n); reload() }
                        .buttonStyle(.borderedProminent).disabled(isApplied(n))
                    Button(L("编辑")) {
                        session.selectScheme(kind, n)
                        dismiss()
                        session.beginEditing(kind, newScheme: false)
                    }
                    Button(L("复制")) { duplicate(k) }
                    Button(L("重命名")) { newName = n; renaming = true }
                    Button(L("导出")) { export(k) }
                    Button(L("删除"), role: .destructive) { confirmDelete = true }
                }
            }
        } else {
            Text(names.isEmpty ? L("暂无方案") : L("选择一个方案")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isApplied(_ n: String) -> Bool { !session.isDisabled(kind) && session.scheme(kind).name == n }

    private func reload() {
        names = KeymapStore.list(pkg, kind)
        if selected == nil || !names.contains(selected!) { selected = names.first { isApplied($0) } ?? names.first }
    }

    private func modified(_ n: String) -> Date? {
        let f = KeymapStore.folder(pkg, kind).appendingPathComponent("\(n).json")
        return try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func duplicate(_ k: Keymap) {
        var c = k
        c.name = KeymapStore.uniqueName(pkg, kind, k.name + L(" 副本"))
        try? KeymapStore.save(c, kind: kind)
        reload()
        selected = c.name
    }

    private func rename() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard let old = selected, !n.isEmpty, n != old else { return }
        if names.contains(n) { session.show(L("重命名的方案名称已被使用")); return }
        try? KeymapStore.rename(pkg, kind, old, to: n)
        session.reloadSchemes()
        reload()
        selected = n
    }

    private func export(_ k: Keymap) {
        let panel = NSSavePanel()
        panel.title = L("导出按键方案")
        panel.nameFieldStringValue = "\(k.name).json"
        if panel.runModal() == .OK, let url = panel.url { try? KeymapStore.export(k, to: url) }
    }

    private func importScheme() {
        let panel = NSOpenPanel()
        panel.title = L("选择要导入的按键方案")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (k, imported) = try KeymapStore.importFile(url, package: pkg)
            session.show(L("导入按键方案成功"))
            kind = imported
            reload()
            selected = k.name
        } catch {
            session.show(L("导入按键方案失败，请重试"))
        }
    }
}
