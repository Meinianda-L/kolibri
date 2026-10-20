import SwiftUI
import KolibriCore

/// First launch: the Android engine, Android 16 system image and adb come from Google
/// (Android SDK licenses), so they are downloaded here instead of shipping with the app.
struct SetupSheet: View {
    struct Check: Decodable {
        var ready: Bool
        var sdk: String
        var missing: [String]
        var bytes: Int64
        var licenses: [String: String]?
    }

    let check: Check
    var onDone: () -> Void
    @State private var accepted = false
    @State private var progress: Double?
    @State private var current = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("下载安卓组件")).font(.title2.weight(.semibold))
                    Text(L("Kolibri 需要 Google 的安卓模拟器引擎和安卓 16 系统镜像（约 {} GB），只需下载一次。")
                        .replacingOccurrences(of: "{}", with: String(format: "%.1f", Double(check.bytes) / 1e9)))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(check.missing, id: \.self) { Label($0, systemImage: "shippingbox").font(.callout) }
            }
            Text(L("Android SDK 许可协议")).font(.headline)
            ScrollView {
                Text((check.licenses ?? [:]).sorted { $0.key < $1.key }.map { "[\($0.key)]\n\n\($0.value)" }.joined(separator: "\n\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            Toggle(L("我已阅读并同意以上许可协议"), isOn: $accepted).disabled(progress != nil)

            if let progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(current).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if let error { Text(error).foregroundStyle(.red).lineLimit(3) }
                Spacer()
                Button(L("退出")) { NSApp.terminate(nil) }.disabled(progress != nil)
                Button(L("同意并下载")) { download() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!accepted || progress != nil)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    private func download() {
        progress = 0
        error = nil
        current = L("连接 Google 下载服务器…")
        Task {
            do {
                try await KolibriCtl.stream(["setup", "--accept-licenses", "--json"]) { line in
                    guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
                    Task { @MainActor in
                        if let done = d["done"] as? Double, let total = d["total"] as? Double, total > 0 {
                            progress = done / total
                            let pkg = d["package"] as? String ?? ""
                            current = (d["unpacking"] as? Bool == true ? L("正在解压 ") : L("正在下载 ")) + pkg
                                + String(format: "  %.0f / %.0f MB", done / 1e6, total / 1e6)
                        }
                    }
                }
                onDone()
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }
}
