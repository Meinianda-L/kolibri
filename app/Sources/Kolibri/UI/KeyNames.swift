import SwiftUI
import KolibriCore

/// Text editor for macro scripts (see `MacroScript` for the syntax).
struct MacroScriptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var press: String
    @State private var release: String
    @State private var error: String?
    let done: ([MacroAction], [MacroAction]) -> Void

    init(press: [MacroAction], release: [MacroAction], done: @escaping ([MacroAction], [MacroAction]) -> Void) {
        _press = State(initialValue: MacroScript.format(press))
        _release = State(initialValue: MacroScript.format(release))
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("宏脚本")).font(.title3.bold())
            Text(L("每行一个动作：tap x y [按住ms] · down x y 手指 · up 手指 · swipe ms x,y x,y … · sleep ms · keydown 键码 · keyup 键码 · loop … end（按住期间循环）。坐标是 0~1 的相对位置。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                editor(L("按下时执行"), $press)
                editor(L("松开时执行"), $release)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                Button(L("完成")) {
                    do {
                        let p = try MacroScript.parse(press), r = try MacroScript.parse(release)
                        done(p, r)
                        dismiss()
                    } catch {
                        self.error = "\(error)"
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 420)
    }

    private func editor(_ title: String, _ text: SwiftUI.Binding<String>) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            TextEditor(text: text).font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden).padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}


enum KeyNames {
    /// Wheel notches as bindable "buttons".
    static let wheelUp = 100
    static let wheelDown = 101

    private static let map: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        36: "⏎", 48: "⇥", 49: L("空格"), 50: "`", 51: "⌫", 53: "Esc", 56: "⇧", 60: L("右⇧"), 59: "⌃", 62: L("右⌃"), 58: "⌥", 61: L("右⌥"), 55: "⌘",
        57: "⇪", 27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 42: "\\",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func name(_ b: KolibriCore.Binding) -> String {
        switch b {
        case let .key(k): return map[k] ?? L("键\(k)")
        case .mouse(0): return L("左键")
        case .mouse(1): return L("右键")
        case .mouse(2): return L("中键")
        case .mouse(3): return L("后侧键")
        case .mouse(4): return L("前侧键")
        case .mouse(wheelUp): return L("滚轮上")
        case .mouse(wheelDown): return L("滚轮下")
        case let .mouse(n): return L("侧键\(n - 2)")
        case let .pad(n): return "🎮\(n.replacingOccurrences(of: "Button ", with: ""))"
        }
    }
}
