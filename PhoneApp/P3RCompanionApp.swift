import SwiftUI
import Combine
import WatchConnectivity

@main
struct P3RCompanionApp: App {
    @StateObject private var connection = WatchConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("手表安装状态") {
                        LabeledContent("随包手表版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")（构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")）")
                        LabeledContent("配对手表", value: connection.pairedText)
                        LabeledContent("手表应用", value: connection.installedText)
                        Button("刷新状态") { connection.refresh() }
                        if let error = connection.error {
                            Text(error).foregroundStyle(.secondary)
                        }
                        Text("此状态表示与本助手的配套关联。旧独立版应用可能仍已安装在手表上。")
                    }
                    Section("免费签名的安装限制") {
                        Text("已在当前设备确认：个人免费开发者签名的手表应用，会被 iPhone「Watch」安装通道拒绝（错误 111）。反复点击安装无法解决，需要通过 Xcode 的手表开发连接直接安装。")
                        Text("下方配套安装步骤需使用允许此通道的签名，尚未验证付费开发团队的安装结果。")
                    }
                    Section("安装到 Apple Watch") {
                        Text("打开 iPhone 的「Watch」应用，在「我的手表」底部找到「P3R 动态表盘」，轻点「安装」。如果已显示在「已在 Apple Watch 上安装」中，则等待更新完成。")
                        Text("安装时让手表靠近 iPhone，保持蓝牙和 Wi-Fi 开启；需要时将手表放在充电器上。")
                    }
                    Section("设置系统表盘") {
                        Text("在手表打开「P3R 动态表盘」一次，然后编辑系统「模块化」表盘，颜色选择「多色」。")
                        Text("中央复杂功能选择「P3R 动画研究」，右下选择「P3R 玻璃时间」，其余关闭。保存并返回表盘。")
                        Text("安装应用不会自动替换当前表盘。动画与时间组件在系统表盘中显示。")
                    }
                }
                .navigationTitle("P3R 表盘助手")
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { connection.refresh() }
                }
            }
        }
    }
}

final class WatchConnection: NSObject, ObservableObject, WCSessionDelegate {
    @Published var pairedText = "正在检查"
    @Published var installedText = "正在检查"
    @Published var error: String?

    override init() {
        super.init()
        guard WCSession.isSupported() else {
            pairedText = "此设备不支持"
            installedText = "不可用"
            return
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func refresh() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            session.activate()
            return
        }
        pairedText = session.isPaired ? "已配对" : "未配对"
        installedText = session.isWatchAppInstalled ? "已关联安装" : "尚未关联"
        // 供本机部署检查读取；此状态不代表手表已更新到当前构建。
        let status: [String: Any] = [
            "paired": session.isPaired,
            "watchAppInstalled": session.isWatchAppInstalled,
            "checkedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: status, options: .sortedKeys),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("watch-install-status.json"), options: .atomic)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.error = error?.localizedDescription
            if activationState == .activated {
                self.refresh()
            } else {
                self.pairedText = "暂时无法读取"
                self.installedText = "请稍后刷新"
            }
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.refresh() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
