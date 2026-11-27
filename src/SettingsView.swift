#if SWIFT_PACKAGE
import NetGuardCore
#endif
import SwiftUI

/// Settings reflect the existing app state. This view never writes
/// network settings, requests privileges, or stores credentials.
final class NetGuardSettingsModel: ObservableObject {
    @Published var alertsEnabled = true
    @Published var focusEnabled = false
    @Published var nativePreview = false
    @Published var displayMode = 0
    @Published var rateUnit = RateDisplayUnit.binaryBytes
    @Published var personalBudget: PersonalDailyBudget?
    @Published var personalReading: PersonalBudgetReading?
    @Published var budgetStatus = "尚未設定"
    @Published var persistenceStatus = "尚未載入"
    @Published var backupBusy = false
    @Published var backupStatus = "尚未執行備份或預檢"
}

struct NetGuardSettingsView: View {
    @ObservedObject var model: NetGuardSettingsModel
    let setAlerts: (Bool) -> Void
    let setFocus: (Bool) -> Void
    let setNativePreview: (Bool) -> Void
    let setDisplayMode: (Int) -> Void
    let setRateUnit: (RateDisplayUnit) -> Void
    let saveBudget: (NetworkScope, String) -> Void
    let clearBudget: () -> Void
    let createBackup: () -> Void
    let inspectBackup: () -> Void
    let createBundle: () -> Void
    let inspectBundle: () -> Void
    let recoverBundle: () -> Void

    @State private var budgetScope = NetworkScope.external
    @State private var budgetGB = ""

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
                Picker("選單列與快速面板網速", selection: Binding(get: { model.rateUnit }, set: setRateUnit)) {
                    Text("KiB/s、MiB/s").tag(RateDisplayUnit.binaryBytes)
                    Text("kbps、Mbps").tag(RateDisplayUnit.decimalBits)
                }
            }
            Section("個人每日流量預算") {
                if let budget = model.personalBudget {
                    Text("已設定：\(scopeLabel(budget.scope)) · \(budget.decimalGigabytes) GB／日")
                    if let reading = model.personalReading {
                        ProgressView(value: reading.fraction)
                        Text(String(format: "已觀測 %.2f GB；未扣除未觀測流量的剩餘估計 %.2f GB", Double(reading.used) / 1e9, Double(reading.remaining) / 1e9))
                            .font(.caption)
                    } else {
                        Text("目前沒有可用的分類觀測").font(.caption)
                    }
                }
                Picker("計量分類", selection: $budgetScope) {
                    Text("宿網").tag(NetworkScope.dorm)
                    Text("校園 Wi-Fi").tag(NetworkScope.campusWifi)
                    Text("外部網路（合計）").tag(NetworkScope.external)
                }
                TextField("每日上限（整數 GB，1–10000）", text: $budgetGB)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("儲存個人預算") { saveBudget(budgetScope, budgetGB) }
                    Button("清除個人預算", action: clearBudget).disabled(model.personalBudget == nil)
                }
                Text(model.budgetStatus).font(.caption)
                Text("GB = 10⁹ bytes；僅供本機分類總量參考，每日台北時間換日。不是單一熱點或 eSIM 的帳單餘額，不修改校方配額、警報或路由。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("資料與安全") {
                LabeledContent("本機儲存", value: model.persistenceStatus)
                HStack {
                    Button("建立歷史資料備份", action: createBackup)
                    Button("檢查備份檔", action: inspectBackup)
                }.disabled(model.backupBusy)
                HStack {
                    Button("建立完整歷史備份", action: createBundle)
                    Button("預檢歷史備份目錄", action: inspectBundle)
                }.disabled(model.backupBusy)
                Button("隔離復原至新目錄", action: recoverBundle).disabled(model.backupBusy)
                Text("隔離復原只建立通過驗證的新副本，不合併或取代正在使用的帳本。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.backupBusy { ProgressView().controlSize(.small) }
                Text(model.backupStatus).font(.caption).foregroundStyle(.secondary)
                Text("一般備份僅含歷史 SQLite；完整歷史備份 V2 另含已保存的程序、AI 工具、連線與事件紀錄；舊版 V1 不含 AI 歷史，具有 SHA-256 清單。各資料來源非同時點快照；不含今日未結算流量、設定或未保存觀測。預檢不會匯入或覆寫現有資料。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("校方配額尚待驗證；自動切換、分流、網路設定回滾與程序控制尚未開放。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("歷史資料保留於本機；匯出由使用者主動選擇。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 390)
    }

    private func scopeLabel(_ scope: NetworkScope) -> String {
        switch scope {
        case .dorm: return "宿網"
        case .campusWifi: return "校園 Wi-Fi"
        case .external: return "外部網路（合計）"
        case .unknown: return "未知"
        }
    }

}
