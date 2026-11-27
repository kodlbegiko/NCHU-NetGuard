#if SWIFT_PACKAGE
import NetGuardCore
#endif
import SwiftUI

struct AutomationView: View {
    let state: AutomationSnapshot
    let setAlerts: (Bool) -> Void
    let setFocus: (Bool) -> Void
    let saveRules: (ObservationRuleSet) -> Void
    @State private var showRules = false
    @State private var editingID: UUID?
    @State private var priority = 100
    @State private var scope = NetworkScope.unknown
    @State private var tier = -1
    @State private var focus = -1
    @State private var connection = -1
    @State private var action = ObservationRuleAction.observe
    @State private var validationStatus = ""

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
            DisclosureGroup("自訂規則 · 唯讀預覽", isExpanded: $showRules) {
                ruleEditor
            }
            Divider()
            Text("尚未開放").font(.subheadline.weight(.medium))
            Text("自動換網、智慧分流、程序暫停、網路設定回滾。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func actionLabel(_ action: ObservationRuleAction) -> String {
        switch action {
        case .observe: return "觀測"
        case .notify: return "建議通知（不發送）"
        case .deferAction: return "建議暫緩"
        }
    }
    private func scopeLabel(_ scope: NetworkScope) -> String {
        switch scope {
        case .dorm: return "宿網"
        case .campusWifi: return "校園 Wi-Fi"
        case .external: return "外部網路"
        case .unknown: return "不限"
        }
    }
    private func previewText(_ preview: ObservationRulePreview?) -> String {
        guard let preview else { return "規則未確認" }
        switch preview.status {
        case .invalid: return "規則無效"
        case .unknown: return "部分條件未確認；暫不判定"
        case .noMatch: return "沒有符合的規則"
        case .conflict: return "相同優先級存在衝突；不採取動作"
        case .matched:
            return preview.action.map { "預覽：" + actionLabel($0) } ?? "未確認"
        }
    }
    private func summary(_ rule: ObservationRule) -> String {
        var conditions: [String] = []
        if let scope = rule.scope { conditions.append(scopeLabel(scope)) }
        if let tier = rule.minimumQuotaTier { conditions.append(AutomationSnapshot.tierLabel(tier) + "以上") }
        if let connected = rule.connected { conditions.append(connected ? "連線已觀測" : "未連線條件") }
        if let focus = rule.focusEnabled { conditions.append(focus ? "重要工作模式" : "一般模式") }
        return conditions.joined(separator: " 且 ")
    }
    private func edit(_ rule: ObservationRule?) {
        editingID = rule?.id
        priority = rule?.priority ?? 100
        scope = rule?.scope ?? .unknown
        tier = rule?.minimumQuotaTier?.rawValue ?? -1
        focus = rule?.focusEnabled.map { $0 ? 1 : 0 } ?? -1
        connection = rule?.connected.map { $0 ? 1 : 0 } ?? -1
        action = rule?.action ?? .observe
        validationStatus = ""
    }
    private func store(_ set: ObservationRuleSet) {
        do {
            let rule = ObservationRule(id: editingID ?? UUID(), priority: priority,
                scope: scope == .unknown ? nil : scope, minimumQuotaTier: LocalQuotaTier(rawValue: tier),
                connected: connection == -1 ? nil : connection == 1, focusEnabled: focus == -1 ? nil : focus == 1,
                action: action)
            saveRules(try set.replacing(rule))
            edit(nil)
        } catch { validationStatus = "至少指定一項條件，並確認規則數量未超過上限。" }
    }
    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.ruleStorageStatus).font(.caption).foregroundStyle(.secondary)
            Text(previewText(state.rulePreview)).font(.subheadline.weight(.medium))
            Text("僅依目前觀測資料進行 Dry Run，不執行通知、換網或程序控制。").font(.caption)
            if let rules = state.rules {
                ForEach(rules.rules.sorted { $0.priority > $1.priority }, id: \.id) { rule in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(rule.priority) · \(actionLabel(rule.action))").font(.subheadline)
                            Spacer()
                            Button("編輯") { edit(rule) }
                            Button("刪除") {
                                do { saveRules(try rules.removing(rule.id)); if editingID == rule.id { edit(nil) } }
                                catch { validationStatus = "無法移除規則" }
                            }
                        }
                        Text(summary(rule)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text(editingID == nil ? "新增規則" : "編輯規則").font(.subheadline.weight(.medium))
                HStack {
                    Button("高用量範本") {
                        edit(nil); priority = 100; tier = LocalQuotaTier.high.rawValue; action = .notify
                    }
                    Button("重要工作範本") {
                        edit(nil); priority = 200; focus = 1; action = .deferAction
                    }
                }
                Stepper("優先級 \(priority)", value: $priority, in: 0...1000)
                Picker("網路範圍", selection: $scope) {
                    ForEach(NetworkScope.allCases, id: \.self) { value in
                        Text(scopeLabel(value)).tag(value)
                    }
                }
                Picker("本機配額門檻", selection: $tier) {
                    Text("不限").tag(-1)
                    Text("任何已量測門檻").tag(0)
                    Text("70%").tag(1)
                    Text("85%").tag(2)
                    Text("95%").tag(3)
                }
                Picker("工作模式", selection: $focus) {
                    Text("不限").tag(-1)
                    Text("一般").tag(0)
                    Text("重要工作").tag(1)
                }
                Picker("連線條件", selection: $connection) {
                    Text("不限").tag(-1)
                    Text("已觀測連線").tag(1)
                    Text("明確確認未連線").tag(0)
                }
                Picker("預覽建議", selection: $action) {
                    ForEach([ObservationRuleAction.observe, .notify, .deferAction], id: \.self) { value in
                        Text(actionLabel(value)).tag(value)
                    }
                }
                HStack {
                    Button("儲存規則") { store(rules) }
                    if editingID != nil { Button("取消") { edit(nil) } }
                }
                if !validationStatus.isEmpty { Text(validationStatus).font(.caption) }
            }
        }
        .padding(.top, 6)
    }
}
