import SwiftUI

/// Settings reflect the existing app state. This view never writes
/// network settings, requests privileges, or stores credentials.
final class NetGuardSettingsModel: ObservableObject {
    @Published var alertsEnabled = true
    @Published var focusEnabled = false
    @Published var nativePreview = false
    @Published var displayMode = 0
    @Published var persistenceStatus = "尚未載入"
}

struct NetGuardSettingsView: View {
    @ObservedObject var model: NetGuardSettingsModel
    let setAlerts: (Bool) -> Void
    let setFocus: (Bool) -> Void
    let setNativePreview: (Bool) -> Void
    let setDisplayMode: (Int) -> Void

    var body: some View {
        Form {
            Section("日常使用") {
                Toggle("本機用量提醒", isOn: Binding(get: { model.alertsEnabled }, set: setAlerts))
                Toggle("重要工作模式（本次執行）", isOn: Binding(get: { model.focusEnabled }, set: setFocus))
                Text("重要工作模式暫停額外探測，保留本機監控，不會修改網路或停止其他程式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("外觀") {
                Toggle("原生快速面板（本次執行預覽）", isOn: Binding(get: { model.nativePreview }, set: setNativePreview))
                Picker("選單列顯示", selection: Binding(get: { model.displayMode }, set: setDisplayMode)) {
                    Text("精簡容量").tag(0)
                    Text("容量與文字").tag(1)
                    Text("即時雙向速率").tag(2)
                    Text("容量與狀態符號").tag(3)
                    Text("純數字").tag(4)
                }
            }
            Section("資料與安全") {
                LabeledContent("本機儲存", value: model.persistenceStatus)
                Text("校方配額尚待驗證；自動切換、分流、網路設定回滾與程序控制尚未開放。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("歷史資料保留於本機；匯出由使用者主動選擇。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 390)
    }
}
