#if SWIFT_PACKAGE
import NetGuardCore
#endif
import SwiftUI

struct AutomationView: View {
    let state: AutomationSnapshot
    let setAlerts: (Bool) -> Void
    let setFocus: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自動化與提醒").font(.headline)
            Text(state.monitoringStatus).font(.subheadline).foregroundStyle(.secondary)
            Toggle("本機用量提醒", isOn: Binding(get: { state.alertsEnabled }, set: setAlerts))
            Text("70% 提醒 · 85% 高用量 · 95% 極高用量")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("目前本機估計", value: AutomationSnapshot.tierLabel(state.quotaTier))
            Divider()
            Toggle("重要工作模式（本次執行）", isOn: Binding(get: { state.focusEnabled }, set: setFocus))
            Text("暫停新額外探測，保留流量採樣與本機提醒。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("今日提醒紀錄").font(.subheadline.weight(.medium))
            LabeledContent("宿網", value: AutomationSnapshot.attemptLabel(state.dormAttempt))
            LabeledContent("校園 Wi-Fi", value: AutomationSnapshot.attemptLabel(state.wifiAttempt))
            Text(state.ledgerStatus).font(.caption).foregroundStyle(.secondary)
            Text("紀錄代表提醒嘗試，不保證 macOS 已顯示通知。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("尚未開放").font(.subheadline.weight(.medium))
            Text("自動換網、智慧分流、程序暫停、網路設定回滾。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
