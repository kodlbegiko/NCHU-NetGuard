#if SWIFT_PACKAGE
import NetGuardCore
#endif
import SwiftUI
import Foundation

final class ManagementModel: ObservableObject {
    @Published var snapshot: ManagementSnapshot?
    @Published var flowBusy = false
    @Published var flowReading: HostProbeCheck.FlowCheckReading?
    @Published var flowStatus = "尚未進行連線層觀測"
    @Published var eventRules = TrafficEventRules.standard
    @Published var eventNotificationsEnabled = false
    @Published var eventNotificationBusy = false
    @Published var eventNotificationStatus = "預設關閉；需主動授權"
    @Published var eventArchiveRows: [TrafficObservationEvent] = []
    @Published var eventArchiveBusy = false
    @Published var eventArchiveStatus = "尚未讀取保存紀錄"
    @Published var automation: AutomationSnapshot?
    @Published var connectionSession: ConnectionSessionReading?
    @Published var connectionSessionStatus = "尚未開始"
    @Published var connectionArchiveRows: [SavedConnectionSession] = []
    @Published var connectionArchiveStatus = "尚未讀取本機紀錄"
    @Published var connectionArchiveBusy = false
    @Published var agentHistoryEnabled = false
    @Published var agentHistoryBusy = false
    @Published var agentHistoryStatus = "預設不保存"
    @Published var agentHistoryDays: [ProcessHistoryDay] = []
    @Published var historyEnabled = false
    @Published var historyBusy = false
    @Published var historyRetention = 30
    @Published var historyStatus = "預設關閉；不儲存程序名稱"
    @Published var historyDays: [ProcessHistoryDay] = []
}

struct ManagementView: View {
    @ObservedObject var model: ManagementModel
    let refresh: () -> Void
    let openProvider: () -> Void
    let setAlerts: (Bool) -> Void
    let setFocus: (Bool) -> Void
    let saveObservationRules: (ObservationRuleSet) -> Void
    let setHistoryEnabled: (Bool) -> Void
    let setAgentHistoryEnabled: (Bool) -> Void
    let reloadAgentHistory: () -> Void
    let deleteAgentHistory: () -> Void
    let setProcessBackground: (Bool) -> Void
    let reloadHistory: () -> Void
    let testDNS: () -> Void
    let measureFlow: (FlowTransport) -> Void
    let configureTrafficEvents: (TrafficEventRules) -> Void
    let setEventNotifications: (Bool) -> Void
    let saveEventArchive: () -> Void
    let loadEventArchive: () -> Void
    let clearEventArchive: () -> Void
    let clearTrafficEvents: () -> Void
    let startConnectionSession: (String, String) -> Void
    let stopConnectionSession: () -> Void
    let saveConnectionArchive: () -> Void
    let loadConnectionArchive: () -> Void
    let deleteConnectionArchive: (UUID) -> Void
    let setHistoryRetention: (Int) -> Void
    let deleteHistory: () -> Void
    @State private var tab = 0
    @State private var showAgentHistory = false
    @State private var confirmDeleteAgentHistory = false
    @State private var showFlowCheck = false
    @State private var flowTransport = FlowTransport.tcp
    @State private var connectionLabel = ""
    @State private var connectionLimit = ""
    @State private var showConnectionArchive = false
    @State private var showCycleBudget = false
    @State private var cycleMonthly = true
    @State private var cycleAnchor = 1
    @State private var cycleLimit = ""
    @State private var cycleStart = Date()
    @State private var cycleEnd = Date()
    @State private var selectedCycleRecords = Set<UUID>()
    @State private var confirmConnectionDeletion = false
    @State private var pendingConnectionDeletion: UUID?
    @State private var selectedInterface: String? = nil
    @State private var processQuery = ""
    @State private var processOrder = 0
    @State private var processMode = 0
    @State private var historyDayIndex = 0
    @State private var historyHour = -1
    @State private var confirmDeleteHistory = false
    @State private var showTrafficEvents = false
    @State private var showEventRules = false
    @State private var showSavedEvents = false
    @State private var confirmClearEventArchive = false
    @State private var highRate = "5"
    @State private var highDuration = "10"
    @State private var surgeRate = "1"
    @State private var surgeFactor = "4"
    @State private var confirmClearTrafficEvents = false

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
                            Text(snapshot.routeStatus).font(.caption)
                            Text("LAN／Internet 個別流量：未確認").font(.caption)
                            experimentalFlowPanel
                            connectionSessionPanel
                            Text("預設路由與位址存在不代表網際網路可達；雙協定使用同一份實體網卡帳本。").font(.caption2).foregroundStyle(.secondary)
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
                                        Text(item.addressEvidence?.description ?? "位址族尚未量測").font(.caption2).foregroundStyle(.secondary)
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
                            Toggle("本次執行允許背景程序監控", isOn: Binding(
                                get: { snapshot.processBackgroundEnabled }, set: setProcessBackground))
                            Text(snapshot.processObservationStatus).font(.caption)
                            Text("預設關閉；背景監控會增加本機探測成本。是否儲存歷史需另外同意。")
                                .font(.caption2).foregroundStyle(.secondary)
                            Picker("統計類型", selection: $processMode) {
                                Text("目前快照").tag(0)
                                Text("本次觀測用量").tag(1)
                                Text("本機歷史").tag(2)
                                Text("AI 工具").tag(3)
                            }.pickerStyle(.segmented)
                            if processMode == 0 {
                                Text(snapshot.processStatus).font(.caption).foregroundStyle(.secondary)
                            } else if processMode == 1 {
                                Text("僅累計獲准觀測期間可辨識的程序增量，不是完整今日用量。").font(.caption).foregroundStyle(.secondary)
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
                            } else if processMode == 3 {
                                agentUsagePanel(snapshot)
                                agentHistoryPanel
                            } else if processMode == 2 {
                                processHistoryPanel
                            } else if let report = snapshot.sessionUsage {
                                Text("有效配對採樣區間：\(report.measuredIntervals)").font(.caption)
                                Text(String(format: "至少一個程序成功配對的區間合計 %.0f 秒；非所有程序的完整覆蓋", report.matchedIntervalSeconds)).font(.caption2).foregroundStyle(.secondary)
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
                            Text("連線品質").font(.headline)
                            Text(snapshot.echoStatus).font(.caption)
                            Text(snapshot.dnsStatus).font(.caption)
                            Button("測試 DNS（example.com）", action: testDNS)
                            Text("手動向 dig 預設解析器查詢 example.com；不代表所有網站或 macOS 系統解析器均正常。").font(.caption2).foregroundStyle(.secondary)
                            Divider()
                            trafficEventsPanel(snapshot.trafficEvents)
                            Divider()
                            ForEach(snapshot.findings, id: \.rawValue) { finding in
                                Label(finding.summary, systemImage: "info.circle")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Divider()
                            Text(snapshot.providerStatus).font(.caption).foregroundStyle(.secondary)
                            Button("開啟校方榜單頁面", action: openProvider)
                            Text("目前不執行網路設定復原或程序控制。").font(.caption).foregroundStyle(.secondary)
                        } else if let automation = model.automation {
                            AutomationView(state: automation, setAlerts: setAlerts, setFocus: setFocus, saveRules: saveObservationRules)
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

    private var processHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("本次執行允許儲存程序歷史", isOn: Binding(
                get: { model.historyEnabled }, set: setHistoryEnabled))
                .disabled(model.historyBusy)
            Text("預設關閉。只儲存程序名稱與雙向觀測增量；不儲存 PID、IP 或目的地。停止後保留舊資料，不包含在一般流量資料庫備份。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.historyStatus).font(.caption)
            Picker("保留期限（本次執行）", selection: Binding(
                get: { model.historyRetention }, set: setHistoryRetention)) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
            }.disabled(model.historyBusy)
            Text("啟用紀錄後，每次成功儲存將依保留期限清理舊檔；未啟用時不自動清理。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("讀取本機歷史", action: reloadHistory)
                Button("刪除所有程序歷史", role: .destructive) { confirmDeleteHistory = true }
            }.disabled(model.historyBusy)
            .alert("刪除所有程序歷史？", isPresented: $confirmDeleteHistory) {
                Button("取消", role: .cancel) {}
                Button("刪除並停止記錄", role: .destructive, action: deleteHistory)
            } message: {
                Text("將刪除本機程序歷史檔案，無法由 NetGuard 復原；一般流量帳本不受影響。")
            }
            if model.historyBusy {
                ProgressView("正在處理本機歷史").controlSize(.small)
            }
            Picker("日期", selection: $historyDayIndex) {
                Text("今日").tag(0)
                Text("昨日").tag(1)
            }.pickerStyle(.segmented)
            Picker("小時（台北時間）", selection: $historyHour) {
                Text("全天觀測").tag(-1)
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            if model.historyDays.indices.contains(historyDayIndex) {
                let day = model.historyDays[historyDayIndex]
                let hour = historyHour < 0 ? nil : historyHour
                let buckets = day.buckets.filter { hour == nil || $0.hour == hour }
                Text(day.day + " · 有效配對區間 " + String(buckets.reduce(0) { $0 + $1.intervals }))
                    .font(.caption)
                if buckets.contains(where: \.limited) {
                    Text("部分增量未計入").font(.caption)
                }
                if buckets.isEmpty {
                    Text("無觀測紀錄，不代表零用量").foregroundStyle(.secondary)
                } else if let rows = try? day.totals(hour: hour) {
                    let ordered = visibleProcesses(rows.map { ProcessSampleRow(name: $0.name, bytes: $0.total) })
                    let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
                    if rows.isEmpty { Text("沒有可歸屬的非零增量").foregroundStyle(.secondary) }
                    ForEach(ordered) { item in
                        if let row = indexed[item.name] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name).lineLimit(2)
                                Text(String(format: "下載 %.2f · 上傳 %.2f MiB", Double(row.download) / 1_048_576, Double(row.upload) / 1_048_576))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                } else {
                    Text("歷史加總無法驗證").foregroundStyle(.secondary)
                }
            } else {
                Text("尚未讀取歷史").foregroundStyle(.secondary)
            }
        }
    }


    private func agentUsagePanel(_ snapshot: ManagementSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 工具與子程序").font(.headline)
            Text("依前後一致的程序階層及執行檔名稱辨識可能的 AI 工作負載；不是經簽章驗證的應用程式身分。只統計本次可觀測增量，與程序總量重疊，不應相加。")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.focusEnabled {
                Text("重要工作模式：暫停額外觀測").font(.caption)
            }
            if let report = snapshot.agentUsage {
                Text("有效配對區間：\(report.measuredIntervals)").font(.caption)
                Text(String(format: "有 AI 程序配對的區間合計 %.0f 秒", report.matchedIntervalSeconds)).font(.caption2).foregroundStyle(.secondary)
                if report.capacityReached { Text("部分增量未計入").font(.caption) }
                let rows = visibleProcesses(report.rows.map { ProcessSampleRow(name: $0.name, bytes: $0.total) })
                let indexed = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.name, $0) })
                if rows.isEmpty {
                    Text("沒有符合條件的已觀測增量；不代表 AI 工具未使用網路。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rows) { item in
                    if let row = indexed[item.name] {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name)
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
                Text("尚無觀測資料").foregroundStyle(.secondary)
            }
            Text("不儲存 AI 歸屬、程序階層或執行檔路徑；不含脫離程序階層的服務、遠端工作或未觀測流量。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }


    private var connectionSessionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("單次連線流量預算").font(.headline)
            Text("自行命名目前連線；僅計量開始後連續可辨識的實體網卡流量。網路變更或資料中斷即停止，不會跨連線或重啟累加。")
                .font(.caption).foregroundStyle(.secondary)
            if let reading = model.connectionSession {
                Text(reading.label + (reading.stopped ? " · 已停止" : " · 觀測中"))
                if reading.intervals > 0 {
                    ProgressView(value: min(1, Double(reading.total) / Double(reading.limitBytes)))
                    Text(String(format: "下載 %.2f GB · 上傳 %.2f GB", Double(reading.received) / 1e9, Double(reading.sent) / 1e9))
                        .font(.caption)
                    Text(String(format: "本機觀測剩餘預算 %.2f GB", Double(reading.remaining) / 1e9)).font(.caption)
                } else {
                    Text("尚無可歸屬的完整採樣區間").font(.caption)
                }
            }
            if model.connectionSession?.stopped != false {
                TextField("連線名稱（例如手機熱點）", text: $connectionLabel)
                TextField("上限 GB（整數 1–10000）", text: $connectionLimit)
                Button("開始新的連線計量") { startConnectionSession(connectionLabel, connectionLimit) }
            } else {
                Button("停止連線計量", action: stopConnectionSession)
            }
            Text(model.connectionSessionStatus).font(.caption)
            connectionArchivePanel
            Text("包含 LAN 流量，與原有帳本重疊；不是電信商帳單，不可與原有總量相加。")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
        }
    }


    private var connectionArchivePanel: some View {
        DisclosureGroup("已保存的單次連線紀錄", isExpanded: $showConnectionArchive) {
            VStack(alignment: .leading, spacing: 8) {
                Text("僅在手動保存時寫入本機；相同名稱仍為獨立紀錄。未保存的計量不會跨 App 重啟保留。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("保存本次計量", action: saveConnectionArchive)
                        .disabled(model.connectionArchiveBusy || model.connectionSession?.stopped != true || (model.connectionSession?.intervals ?? 0) == 0)
                    Button("讀取紀錄", action: loadConnectionArchive)
                        .disabled(model.connectionArchiveBusy)
                }
                if model.connectionArchiveBusy { ProgressView().controlSize(.small) }
                Text(model.connectionArchiveStatus).font(.caption)
                connectionCyclePanel
                ForEach(model.connectionArchiveRows) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.label).lineLimit(2)
                            Text(row.savedAt, style: .date).font(.caption)
                            Text(String(format: "觀測 %.2f / %.2f GB · %d 個區間", Double(row.total) / 1e9, Double(row.limitBytes) / 1e9, row.intervals))
                                .font(.caption)
                            Text(String(format: "下載 %.2f · 上傳 %.2f GB", Double(row.received) / 1e9, Double(row.sent) / 1e9))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("刪除", role: .destructive) {
                            pendingConnectionDeletion = row.id
                            confirmConnectionDeletion = true
                        }.disabled(model.connectionArchiveBusy)
                    }
                    Divider()
                }
                Text("最多保存 1000 筆；不含 IP、SSID 或硬體識別，不包含在一般流量資料庫備份中。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .alert("刪除這筆連線紀錄？", isPresented: $confirmConnectionDeletion) {
            Button("取消", role: .cancel) { pendingConnectionDeletion = nil }
            Button("刪除", role: .destructive) {
                if let id = pendingConnectionDeletion { deleteConnectionArchive(id) }
                pendingConnectionDeletion = nil
            }
        } message: {
            Text("僅刪除選取的本機紀錄，不影響一般流量帳本。")
        }
    }


    private var cyclePeriod: ConnectionBudgetPeriod? {
        guard let gb = UInt64(cycleLimit.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if cycleMonthly {
            return try? ConnectionBudgetPeriod.monthly(at: Date(), anchorDay: cycleAnchor, decimalGB: gb)
        }
        return try? ConnectionBudgetPeriod(startDay: ProcessHistoryStore.hour(at: cycleStart).day,
            endDay: ProcessHistoryStore.hour(at: cycleEnd).day, decimalGB: gb)
    }

    private var connectionCyclePanel: some View {
        DisclosureGroup("週期流量預算試算", isExpanded: $showCycleBudget) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("週期", selection: $cycleMonthly) {
                    Text("每月重置").tag(true)
                    Text("自訂日期").tag(false)
                }.pickerStyle(.segmented)
                if cycleMonthly {
                    Picker("每月重置日（台北時間）", selection: $cycleAnchor) {
                        ForEach(1...31, id: \.self) { day in Text("\(day) 日").tag(day) }
                    }
                    Text("月份不足指定天數時，使用當月最後一天。").font(.caption2)
                } else {
                    DatePicker("開始日", selection: $cycleStart, displayedComponents: .date)
                    DatePicker("結束日", selection: $cycleEnd, displayedComponents: .date)
                }
                TextField("週期上限 GB（整數 1–10000）", text: $cycleLimit)
                Text("只依保存日期篩選，請確認選取紀錄的實際用量屬於本週期。這不是電信商帳單，不會自動歸屬網路或保留試算設定。")
                    .font(.caption2).foregroundStyle(.secondary)
                if let period = cyclePeriod {
                    Text(period.startDay + " 至 " + period.endDay + "（台北時間）").font(.caption)
                    let candidates = model.connectionArchiveRows.filter { period.includes($0) }
                    if candidates.isEmpty { Text("此期間沒有已讀取的保存紀錄").font(.caption) }
                    ForEach(candidates) { row in
                        Toggle(isOn: Binding(get: { selectedCycleRecords.contains(row.id) },
                            set: { enabled in
                                if enabled { selectedCycleRecords.insert(row.id) }
                                else { selectedCycleRecords.remove(row.id) }
                            })) {
                            VStack(alignment: .leading) {
                                Text(row.label)
                                Text(row.savedAt, style: .date).font(.caption2)
                                Text(String(format: "%.2f GB", Double(row.total) / 1e9)).font(.caption)
                            }
                        }
                    }
                    Button("清除選取") { selectedCycleRecords.removeAll() }
                        .disabled(selectedCycleRecords.isEmpty)
                    if selectedCycleRecords.isEmpty {
                        Text("請選取紀錄；未選取不代表零用量").font(.caption)
                    } else if let reading = try? period.summarize(records: model.connectionArchiveRows, selected: selectedCycleRecords) {
                        ProgressView(value: min(1, Double(reading.total) / Double(reading.limitBytes)))
                        Text(String(format: "%d 筆 · 已觀測 %.2f GB · 預算餘額試算 %.2f GB", reading.recordCount, Double(reading.total) / 1e9, Double(reading.remaining) / 1e9)).font(.caption)
                        Text(String(format: "下載 %.2f · 上傳 %.2f GB", Double(reading.received) / 1e9, Double(reading.sent) / 1e9)).font(.caption)
                    } else {
                        Text("選取包含已刪除或非本期紀錄，或數值無法驗證；請清除後重新選取。").font(.caption)
                    }
                } else {
                    Text("請輸入有效日期及週期上限。").font(.caption)
                }
            }
            .environment(\.timeZone, TimeZone(identifier: "Asia/Taipei")!)
            .disabled(model.connectionArchiveBusy)
        }
    }


    private func trafficEventsPanel(_ events: [TrafficObservationEvent]) -> some View {
        DisclosureGroup("流量事件（本次執行）", isExpanded: $showTrafficEvents) {
            VStack(alignment: .leading, spacing: 8) {
                Text("目前規則：持續高流量 \(model.eventRules.highMiB) MiB/s、\(model.eventRules.highSeconds) 秒；突增至少 \(model.eventRules.surgeMiB) MiB/s 且達基準 \(model.eventRules.surgeMultiplier) 倍。不是惡意流量或違規判定。")
                    .font(.caption2).foregroundStyle(.secondary)
                eventRulesPanel
                Toggle("本次執行允許異常流量通知", isOn: Binding(get: { model.eventNotificationsEnabled }, set: setEventNotifications))
                    .disabled(model.eventNotificationBusy)
                if model.eventNotificationBusy { ProgressView().controlSize(.small) }
                Text(model.eventNotificationStatus).font(.caption)
                Text("僅新發生的高流量或突增事件；全域冷卻 120 秒，重要工作模式暫停通知。不補發歷史事件。")
                    .font(.caption2).foregroundStyle(.secondary)
                if events.isEmpty {
                    Text("尚無符合規則的觀測事件；不代表網路安全或完整覆蓋。").font(.caption)
                }
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.kind.title).fontWeight(.medium)
                            Spacer()
                            Text(event.date, style: .time).font(.caption)
                        }
                        Text(event.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                        Text(eventRuleDescription(event)).font(.caption2).foregroundStyle(.secondary)
                        if let rate = event.bytesPerSecond {
                            Text(String(format: "合計速率 %.2f MiB/s", rate / 1_048_576)).font(.caption)
                        }
                        if let reference = event.referenceBytesPerSecond {
                            Text(String(format: "前段中位數 %.2f MiB/s", reference / 1_048_576)).font(.caption)
                        }
                        if let duration = event.duration {
                            Text(String(format: "連續觀測 %.0f 秒", duration)).font(.caption)
                        }
                        if event.kind == .observationGap {
                            Text("無法確認中斷期間的流量，不補算未知用量。").font(.caption)
                        }
                    }
                    Divider()
                }
                Button("清除本次事件", role: .destructive) { confirmClearTrafficEvents = true }
                    .disabled(events.isEmpty)
                Text("本次最多保留 100 筆於記憶體；僅手動保存時寫入磁碟；通知需另行授權，不阻斷連線。").font(.caption2).foregroundStyle(.secondary)
                savedEventsPanel(events)
            }
        }
        .alert("清除本次流量事件？", isPresented: $confirmClearTrafficEvents) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive, action: clearTrafficEvents)
        } message: {
            Text("清除事件及偵測基準，不變更流量帳本。")
        }
    }


    private var proposedEventRules: TrafficEventRules? {
        guard let h = Int(highRate), let t = Int(highDuration),
              let s = Int(surgeRate), let f = Int(surgeFactor) else { return nil }
        return TrafficEventRules(highMiB: h, highSeconds: t, surgeMiB: s, surgeMultiplier: f)
    }

    private var eventRulesPanel: some View {
        DisclosureGroup("調整偵測門檻", isExpanded: $showEventRules) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("高流量 MiB/s（1–1024）", text: $highRate)
                TextField("持續秒數（5–120）", text: $highDuration)
                TextField("突增最低 MiB/s（1–1024）", text: $surgeRate)
                TextField("突增倍率（2–20）", text: $surgeFactor)
                HStack {
                    Button("套用門檻") {
                        if let rules = proposedEventRules { configureTrafficEvents(rules) }
                    }.disabled(proposedEventRules == nil)
                    Button("恢復預設") {
                        configureTrafficEvents(.standard)
                        loadEventRuleFields(.standard)
                    }
                }
                if proposedEventRules == nil {
                    Text("請輸入範圍內的整數。").font(.caption)
                }
                Text("套用後重新建立觀測基準；先前事件仍保留，門檻不會回溯重算。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onChange(of: showEventRules) { _, expanded in
            if expanded { loadEventRuleFields(model.eventRules) }
        }
    }

    private func loadEventRuleFields(_ rules: TrafficEventRules) {
        highRate = String(rules.highMiB)
        highDuration = String(rules.highSeconds)
        surgeRate = String(rules.surgeMiB)
        surgeFactor = String(rules.surgeMultiplier)
    }


    private func eventRuleDescription(_ event: TrafficObservationEvent) -> String {
        switch event.kind {
        case .sustainedHigh:
            return "觸發規則：\(event.rules.highMiB) MiB/s、\(event.rules.highSeconds) 秒"
        case .surge:
            return "觸發規則：至少 \(event.rules.surgeMiB) MiB/s、基準 \(event.rules.surgeMultiplier) 倍"
        case .observationGap:
            return "採樣連續性中斷"
        }
    }

    private func savedEventsPanel(_ events: [TrafficObservationEvent]) -> some View {
        DisclosureGroup("已保存的事件歷史", isExpanded: $showSavedEvents) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("保存本次事件", action: saveEventArchive)
                        .disabled(events.isEmpty || model.eventArchiveBusy)
                    Button("讀取歷史", action: loadEventArchive).disabled(model.eventArchiveBusy)
                }
                Text(model.eventArchiveStatus).font(.caption)
                if model.eventArchiveBusy { ProgressView().controlSize(.small) }
                ForEach(model.eventArchiveRows) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.kind.title).fontWeight(.medium)
                        Text(event.date, style: .date).font(.caption)
                        Text(event.date, style: .time).font(.caption)
                        Text(eventRuleDescription(event)).font(.caption2)
                        if let rate = event.bytesPerSecond {
                            Text(String(format: "觀測速率 %.2f MiB/s", rate / 1_048_576)).font(.caption)
                        }
                        if let reference = event.referenceBytesPerSecond {
                            Text(String(format: "基準 %.2f MiB/s", reference / 1_048_576)).font(.caption)
                        }
                        if let duration = event.duration {
                            Text(String(format: "觀測 %.0f 秒", duration)).font(.caption)
                        }
                    }
                    Divider()
                }
                Button("清除保存歷史", role: .destructive) { confirmClearEventArchive = true }
                    .disabled(model.eventArchiveBusy || model.eventArchiveRows.isEmpty)
                Text("最多 1000 筆；不保存 IP、程序名稱或目的地。清除歷史不會清除本次事件。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .alert("清除已保存的事件歷史？", isPresented: $confirmClearEventArchive) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive, action: clearEventArchive)
        } message: {
            Text("此操作只清除本機事件歷史，不會改變用量帳本。")
        }
    }


    private var experimentalFlowPanel: some View {
        DisclosureGroup("連線層觀測（實驗性）", isExpanded: $showFlowCheck) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("協定", selection: $flowTransport) {
                    Text("TCP").tag(FlowTransport.tcp)
                    Text("UDP").tag(FlowTransport.udp)
                }.pickerStyle(.segmented).disabled(model.flowBusy)
                Button("執行一次觀測") { measureFlow(flowTransport) }.disabled(model.flowBusy)
                if model.flowBusy { ProgressView().controlSize(.small) }
                Text(model.flowStatus).font(.caption)
                if let reading = model.flowReading {
                    Text("上次觀測：" + reading.transport.rawValue.uppercased()).font(.caption)
                    if let coverage = reading.coverage {
                        Text("匹配 \(coverage.matchedRows)／\(coverage.currentRows) 筆有效紀錄；\(String(format: "%.1f", coverage.elapsedSeconds)) 秒").font(.caption)
                    }
                    if let totals = reading.totals {
                        ForEach(totals.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                            if let value = totals[kind] {
                                HStack {
                                    Text(flowKindLabel(kind))
                                    Spacer()
                                    Text(String(format: "↓ %.2f ↑ %.2f MiB", Double(value.received) / 1_048_576, Double(value.sent) / 1_048_576))
                                        .monospacedDigit()
                                }.font(.caption)
                            }
                        }
                    }
                    if reading.tunnelCandidate {
                        Text("觀測到疑似隧道介面，可能存在內外層重疊。").font(.caption)
                    }
                }
                Text("僅顯示本次可匹配的連線增量；未觀測的類別不等於零。不是 LAN／Internet 或帳單用量，不與網卡帳本或另一協定相加。不保存端點或結果。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func flowKindLabel(_ kind: DestinationAddressKind) -> String {
        switch kind {
        case .loopback: return "Loopback"
        case .linkLocal: return "Link-local"
        case .privateSpace: return "私有位址"
        case .sharedSpace: return "共用位址"
        case .multicast: return "Multicast"
        case .specialUse: return "特殊用途"
        case .publicCandidate: return "公有位址候選"
        case .unknown: return "未知"
        }
    }


    private func agentTrendPanel(_ trend: AgentTrend) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("七日已觀測流量").font(.headline)
            Text("有觀測的日期 \(trend.observedDays)／\(trend.days.count)；今日尚未結束。").font(.caption)
            let maxBytes = Double(max(1, trend.days.map(\.total).max() ?? 0))
            ForEach(trend.days) { day in
                HStack {
                    Text(String(day.day.suffix(5))).font(.caption.monospacedDigit()).frame(width: 44)
                    if !day.hasObservation {
                        Text("無觀測").font(.caption).foregroundStyle(.secondary)
                    } else if day.total == 0 {
                        Text("已觀測；無可歸屬非零增量").font(.caption2)
                    } else {
                        GeometryReader { geometry in
                            HStack(spacing: 0) {
                                Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * CGFloat(Double(day.download) / maxBytes))
                                Rectangle().fill(Color.teal).frame(width: geometry.size.width * CGFloat(Double(day.upload) / maxBytes))
                                Spacer(minLength: 0)
                            }
                        }.frame(height: 12).accessibilityHidden(true)
                        Text(String(format: "%.2f MiB", Double(day.total) / 1_048_576)).font(.caption.monospacedDigit())
                    }
                    if day.limited { Text("部分").font(.caption2).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(day.hasObservation ? day.day + "，已觀測下載 \(day.download) bytes，上傳 \(day.upload) bytes" + (day.limited ? "，部分資料未計入" : "") : day.day + "，無觀測")
            }
            HStack {
                Label("下載", systemImage: "square.fill").foregroundStyle(Color.accentColor)
                Label("上傳", systemImage: "square.fill").foregroundStyle(Color.teal)
            }.font(.caption2)
            Text("期間工具排名（觀測值）").font(.subheadline.weight(.medium))
            if trend.ranking.isEmpty { Text("無可歸屬資料").font(.caption) }
            ForEach(trend.ranking) { row in
                HStack {
                    Text(row.name)
                    Spacer()
                    Text(String(format: "%.2f MiB", Double(row.total) / 1_048_576)).monospacedDigit()
                }.font(.caption)
            }
            Text("排名僅依已觀測位元組；不代表完整用量、算力、成本或效能。").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var agentHistoryPanel: some View {
        DisclosureGroup("AI 工具歷史（最近七日）", isExpanded: $showAgentHistory) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("本次執行允許儲存 AI 工具分類", isOn: Binding(
                    get: { model.agentHistoryEnabled }, set: setAgentHistoryEnabled))
                    .disabled(model.agentHistoryBusy)
                Text("只保存固定 AI 工具分類與已觀測增量，保留 30 天（成功儲存時清理）。與程序統計重疊，不應相加；完整歷史備份 V2 包含已保存的 AI 紀錄。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("讀取歷史", action: reloadAgentHistory)
                    Button("刪除 AI 歷史", role: .destructive) { confirmDeleteAgentHistory = true }
                }.disabled(model.agentHistoryBusy)
                if model.agentHistoryBusy { ProgressView().controlSize(.small) }
                Text(model.agentHistoryStatus).font(.caption)
                if !model.agentHistoryDays.isEmpty {
                    if let trend = try? AgentHistoryAnalytics.summarize(model.agentHistoryDays) {
                        agentTrendPanel(trend)
                    } else { Text("趨勢資料無法驗證").font(.caption) }
                }
                ForEach(model.agentHistoryDays, id: \.day) { day in
                    Text(day.day + " · " + String(day.intervals) + " 個配對區間").font(.caption.weight(.medium))
                    if day.buckets.isEmpty {
                        Text("無觀測紀錄").font(.caption2).foregroundStyle(.secondary)
                    } else if let rows = try? day.totals() {
                        if rows.isEmpty { Text("無可歸屬非零增量").font(.caption2) }
                        ForEach(rows) { row in
                            HStack {
                                Text(row.name)
                                Spacer()
                                Text(String(format: "↓ %.2f ↑ %.2f MiB", Double(row.download) / 1_048_576, Double(row.upload) / 1_048_576)).monospacedDigit()
                            }.font(.caption)
                        }
                    } else { Text("無法驗證加總").font(.caption) }
                    if day.limited { Text("部分資料未計入").font(.caption2) }
                    Divider()
                }
            }
        }
        .alert("刪除 AI 工具歷史？", isPresented: $confirmDeleteAgentHistory) {
            Button("取消", role: .cancel) {}
            Button("刪除並停止保存", role: .destructive, action: deleteAgentHistory)
        }
    }

}
