import SwiftUI
import Foundation

final class ManagementModel: ObservableObject {
    @Published var snapshot: ManagementSnapshot?
    @Published var automation: AutomationSnapshot?
}

struct ManagementView: View {
    @ObservedObject var model: ManagementModel
    let refresh: () -> Void
    let openProvider: () -> Void
    let setAlerts: (Bool) -> Void
    let setFocus: (Bool) -> Void
    @State private var tab = 0
    @State private var selectedInterface: String? = nil
    @State private var processQuery = ""
    @State private var processOrder = 0
    @State private var processMode = 0

    private func visibleProcesses(_ rows: [ProcessSampleRow]) -> [ProcessSampleRow] {
        ProcessSamplePresentation.visible(rows, query: processQuery,
                                          order: ProcessSampleOrdering(rawValue: processOrder) ?? .descendingBytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("網路管理").font(.title2.weight(.semibold))
                    Text("唯讀監控，不變更系統設定").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: refresh) { Label("重新整理", systemImage: "arrow.clockwise") }
            }
            Picker("功能", selection: $tab) {
                Text("網路連線").tag(0)
                Text("應用程式").tag(1)
                Text("診斷").tag(2)
                Text("自動化").tag(3)
            }.pickerStyle(.segmented)
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if tab == 0 {
                            Text(snapshot.connectionStatus).font(.subheadline)
                            Text(snapshot.latencyStatus).font(.caption).foregroundStyle(.secondary)
                            Text(snapshot.tunnelStatus).font(.caption).foregroundStyle(.secondary)
                            Picker("查看網卡", selection: $selectedInterface) {
                                Text("全部實體網卡").tag(nil as String?)
                                if let selectedInterface, !snapshot.interfaces.contains(where: { $0.name == selectedInterface }) {
                                    Text(selectedInterface + "（不可用）").tag(Optional(selectedInterface))
                                }
                                ForEach(snapshot.interfaces) { item in
                                    Text(item.name).tag(Optional(item.name))
                                }
                            }
                            Text("僅篩選顯示；不變更路由或流量帳本。").font(.caption2).foregroundStyle(.secondary)
                            if snapshot.interfaces.isEmpty {
                                Text("尚無介面採樣").foregroundStyle(.secondary)
                            }
                            if let selectedInterface, !snapshot.interfaces.contains(where: { $0.name == selectedInterface }) {
                                Text("選取的網卡目前不可用").foregroundStyle(.secondary)
                            }
                            ForEach(snapshot.interfaces.filter { selectedInterface == nil || $0.name == selectedInterface }) { item in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(item.name).font(.system(.body, design: .monospaced))
                                        Text(item.scopeLabel).font(.caption).foregroundStyle(.secondary)
                                        if let rate = item.rate {
                                            Text(String(format: "↓ %.2f · ↑ %.2f MiB/s", rate.download / 1_048_576, rate.upload / 1_048_576))
                                                .font(.caption.monospacedDigit())
                                        } else {
                                            Text("速率未量測").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if item.isDefault { Text("預設路由").font(.caption) }
                                }
                                Divider()
                            }
                            Text("自動切換與分流尚未開放。").font(.caption).foregroundStyle(.secondary)
                        } else if tab == 1 {
                            Picker("統計類型", selection: $processMode) {
                                Text("目前快照").tag(0)
                                Text("本次觀測用量").tag(1)
                            }.pickerStyle(.segmented)
                            if processMode == 0 {
                                Text(snapshot.processStatus).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("僅累計面板開啟期間可辨識的程序增量，不是完整今日用量。").font(.caption).foregroundStyle(.secondary)
                            }
                            TextField(processMode == 0 ? "搜尋目前前 20 個程序" : "搜尋已觀測程序", text: $processQuery)
                                .textFieldStyle(.roundedBorder)
                            Picker("排序", selection: $processOrder) {
                                Text("流量由大到小").tag(0)
                                Text("流量由小到大").tag(1)
                                Text("名稱").tag(2)
                            }.pickerStyle(.segmented)
                            if processMode == 0 {
                                if snapshot.processes.isEmpty {
                                    Text("沒有可顯示的近期程序採樣").foregroundStyle(.secondary)
                                } else if visibleProcesses(snapshot.processes).isEmpty {
                                    Text("沒有符合搜尋的程序").foregroundStyle(.secondary)
                                }
                                ForEach(visibleProcesses(snapshot.processes)) { item in
                                    HStack {
                                        Text(item.name).lineLimit(2)
                                        Spacer()
                                        Text(String(format: "%.2f MiB", Double(item.bytes) / 1_048_576)).monospacedDigit()
                                    }
                                    Divider()
                                }
                            } else if let report = snapshot.sessionUsage {
                                Text("有效配對採樣區間：\(report.measuredIntervals)").font(.caption)
                                if snapshot.focusEnabled { Text("重要工作模式：累計暫停").font(.caption) }
                                if report.capacityReached { Text("已達紀錄上限，部分增量未計入").font(.caption) }
                                if report.rows.isEmpty { Text("尚無可歸屬的非零增量").foregroundStyle(.secondary) }
                                let ordered = visibleProcesses(report.rows.map { ProcessSampleRow(name: $0.name, bytes: $0.total) })
                                let indexed = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.name, $0) })
                                ForEach(ordered) { item in
                                    if let row = indexed[item.name] {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(row.name).lineLimit(2)
                                                Spacer()
                                                Text(String(format: "%.2f MiB", Double(row.total) / 1_048_576)).monospacedDigit()
                                            }
                                            Text(String(format: "下載 %.2f · 上傳 %.2f MiB", Double(row.received) / 1_048_576, Double(row.sent) / 1_048_576))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Divider()
                                    }
                                }
                            } else {
                                Text("尚無工作階段資料").foregroundStyle(.secondary)
                            }
                        } else if tab == 2 {
                            ForEach(snapshot.findings, id: \.rawValue) { finding in
                                Label(finding.summary, systemImage: "info.circle")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                            Text(snapshot.providerStatus).font(.caption).foregroundStyle(.secondary)
                            Button("開啟校方榜單頁面", action: openProvider)
                            Text("目前不執行網路設定復原或程序控制。").font(.caption).foregroundStyle(.secondary)
                        } else if let automation = model.automation {
                            AutomationView(state: automation, setAlerts: setAlerts, setFocus: setFocus)
                        } else {
                            Text("正在讀取自動化狀態").foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("正在讀取本機資料").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 400)
    }
}
