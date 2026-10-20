import GameController
import SwiftUI
import KolibriCore

/// The popover behind the 使用键鼠 / 使用手柄 toolbar buttons, laid out as:
/// 键鼠|手柄 header, 键位方案 list (with 不使用方案, 新建方案, 键位编辑),
/// 键位提示 (show + 透明度) and 操作控制 (lock key, X/Y sensitivity correction).
struct KeymapPopover: View {
    @ObservedObject var session: GameSession
    @State var kind: SchemeKind
    var close: () -> Void
    @State private var showManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $kind) {
                Text(L("键鼠")).tag(SchemeKind.keyboard)
                Text(L("手柄")).tag(SchemeKind.gamepad)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if kind == .gamepad && GCController.controllers().isEmpty {
                Label(L("没有识别到手柄，请检查设备连接状况。"), systemImage: "gamecontroller")
                    .font(.callout).foregroundStyle(.secondary)
            }

            section(L("键位方案")) {
                VStack(spacing: 2) {
                    row(L("不使用方案"), selected: session.isDisabled(kind)) { session.disableScheme(kind) }
                    let names = session.schemes(kind)
                    if names.isEmpty {
                        Text(kind == .keyboard ? L("暂无键鼠方案") : L("暂无手柄方案"))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
                    }
                    ForEach(names, id: \.self) { n in
                        row(n, selected: !session.isDisabled(kind) && session.scheme(kind).name == n) { session.selectScheme(kind, n) }
                    }
                }
                HStack {
                    Button(L("新建方案")) {
                        close()
                        session.beginEditing(kind, newScheme: true)
                    }
                    Spacer()
                    Button(L("方案管理")) { showManage = true }
                    Button(L("键位编辑")) {
                        close()
                        session.beginEditing(kind, newScheme: session.isDisabled(kind) || session.schemes(kind).isEmpty)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            section(L("键位提示")) {
                Toggle(L("显示按键提示（⌃⌘K）"), isOn: $session.hintsVisible)
                HStack {
                    Text(L("透明度"))
                    Slider(value: SwiftUI.Binding(
                        get: { session.keymap.hintOpacity },
                        set: { session.setHintOpacity($0, kind: kind) }), in: 0.1...1)
                    Text("\(Int(session.keymap.hintOpacity * 100))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
            }

            if kind == .keyboard {
                section(L("操作控制")) {
                    HStack {
                        Text(L("锁定/解锁跟随视角"))
                        Spacer()
                        Text(session.keyboardScheme.aimToggle.map(KeyNames.name) ?? L("未设置")).foregroundStyle(.secondary)
                    }
                    stepper(L("X轴灵敏度修正"), $session.sensitivityX)
                    stepper(L("Y轴灵敏度修正"), $session.sensitivityY)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .sheet(isPresented: $showManage) { KeymapManageView(session: session, kind: kind) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stepper(_ title: String, _ value: SwiftUI.Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button { value.wrappedValue = max(0.1, ((value.wrappedValue - 0.1) * 10).rounded() / 10) } label: { Image(systemName: "minus") }
            Text(String(format: "%.1f", value.wrappedValue)).monospacedDigit().frame(width: 34)
            Button { value.wrappedValue = min(5, ((value.wrappedValue + 0.1) * 10).rounded() / 10) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.borderless)
    }
}
