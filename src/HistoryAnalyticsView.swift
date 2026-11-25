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
    let today: String
    let storageHealthy: Bool
    @State private var days = 7
    @State private var exporting = false
    @State private var document: HistoryCSVDocument?
    @State private var exportMessage = ""

    private var report: HistoryPeriod? {
        try? HistoryAnalytics.period(endingBefore: today, days: days, records: records)
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
                        document = HistoryCSVDocument(csv: report.csv())
                        exporting = true
                    }
                } label: {
                    Label("匯出 CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(report == nil || !storageHealthy)
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
