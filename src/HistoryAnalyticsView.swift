import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct HistoryCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    let data: Data
    init(csv: String) { data = Data(csv.utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct HistoryAnalyticsView: View {
    let records: [HistoryDay]
    let scopedRecords: [NetworkScope: [HistoryDay]]
    let today: String
    @State private var scope: NetworkScope? = nil
    let storageHealthy: Bool
    @State private var days = 7
    @State private var exporting = false
    @State private var document: HistoryCSVDocument?
    @State private var exportMessage = ""

    private var report: HistoryPeriod? {
        try? HistoryAnalytics.period(endingBefore: today, days: days, records: scope.map { scopedRecords[$0] ?? [] } ?? records)
    }
    private func gib(_ bytes: Double) -> String {
        String(format: "%.2f GiB", bytes / 1_073_741_824)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("歷史流量").font(.title2.weight(.semibold))
                    Text("本機統計・台灣日期・已結束的日期").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let report {
                        document = HistoryCSVDocument(csv: report.csv(scope: scope))
                        exporting = true
                    }
                } label: {
                    Label("匯出 CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil || !storageHealthy)
            }
            Picker("網路類型", selection: $scope) {
                Text("全部紀錄（含舊資料）").tag(nil as NetworkScope?)
                Text("宿網").tag(Optional(NetworkScope.dorm))
                Text("校園 Wi-Fi").tag(Optional(NetworkScope.campusWifi))
                Text("外部網路").tag(Optional(NetworkScope.external))
                Text("未分類").tag(Optional(NetworkScope.unknown))
            }
            if scope != nil {
                Text("僅顯示新版有分類的非零觀測；未出現的日期不代表零流量。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("期間", selection: $days) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
            }.pickerStyle(.segmented)
            if !storageHealthy {
                Text("資料庫或舊資料匯入異常；目前紀錄可能不完整，暫停匯出。")
                    .foregroundStyle(.secondary)
            }
            if let report {
                HStack {
                    VStack(alignment: .leading) {
                        Text("有紀錄日").font(.caption).foregroundStyle(.secondary)
                        Text("\(report.recordedDays) / \(days)").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("有紀錄日平均").font(.caption).foregroundStyle(.secondary)
                        Text(report.averageBytes.map(gib) ?? "無紀錄").font(.title3.weight(.semibold)).monospacedDigit()
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                HistoryTrafficChart(period: report)
                Text("無紀錄不等於零流量；歷史資料可能有採樣缺口，不代表校方計費用量。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(report.rows.reversed()) { row in
                            HStack {
                                Text(row.day).font(.system(.caption, design: .monospaced))
                                Spacer()
                                if let record = row.record {
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(gib(Double(record.total))).monospacedDigit()
                                        Text(record.download == nil ? "上下傳未分類" :
                                             "下 " + gib(Double(record.download ?? 0)) +
                                             " · 上 " + gib(Double(record.upload ?? 0)))
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text("無紀錄").foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }
            } else {
                Text("歷史資料無法驗證。").foregroundStyle(.secondary)
            }
            if !exportMessage.isEmpty {
                Text(exportMessage).font(.caption)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 400)
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: .commaSeparatedText, defaultFilename: "NetGuard-history") { result in
            switch result {
            case .success: exportMessage = "匯出完成"
            case .failure: exportMessage = "匯出未完成；本機紀錄未變更"
            }
        }
    }
}


/// Native SwiftUI stacked bars. Missing, zero and unknown directions are
/// distinguished by symbols and accompanying accessible text.
struct HistoryTrafficChart: View {
    let period: HistoryPeriod
    private let chartHeight: CGFloat = 112
    private var maximum: Double { max(1, Double(period.rows.compactMap { $0.record?.total }.max() ?? 0)) }

    private func barHeight(_ bytes: UInt64) -> CGFloat {
        CGFloat(Double(bytes) / maximum) * chartHeight
    }

    private func description(_ row: HistoryPeriodDay) -> String {
        guard let record = row.record else { return row.day + "，無紀錄" }
        if let dl = record.download, let ul = record.upload {
            return row.day + "，下載 \(dl) bytes，上傳 \(ul) bytes"
        }
        return row.day + "，總量 \(record.total) bytes，上下傳未分類"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("每日流量").font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "最高 %.2f GiB", Double(period.rows.compactMap { $0.record?.total }.max() ?? 0) / 1_073_741_824))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: period.rows.count > 30 ? 1 : 3) {
                ForEach(period.rows) { row in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        if let record = row.record {
                            if record.total == 0 {
                                Capsule().strokeBorder(record.download == nil ? Color.orange : Color.secondary, lineWidth: 1)
                                    .frame(height: 4)
                            } else if let dl = record.download, let ul = record.upload {
                                Rectangle().fill(Color.teal).frame(height: barHeight(ul))
                                Rectangle().fill(Color.accentColor).frame(height: barHeight(dl))
                            } else {
                                Rectangle().fill(Color.orange.opacity(0.75)).frame(height: barHeight(record.total))
                            }
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: chartHeight + 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(description(row))
                }
            }
            HStack {
                Text(period.rows.first?.day ?? "")
                Spacer()
                Text(period.rows.last?.day ?? "")
            }
            .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Label("下載", systemImage: "square.fill").foregroundStyle(Color.accentColor)
                Label("上傳", systemImage: "square.fill").foregroundStyle(Color.teal)
                Label("未分類", systemImage: "square.fill").foregroundStyle(Color.orange)
                Label("無紀錄", systemImage: "minus")
                Label("零", systemImage: "capsule")
            }.font(.caption2)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
