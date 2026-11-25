import SwiftUI
import Foundation

final class QuickPanelModel: ObservableObject {
    @Published var state = QuickPanelState.initial
}

struct QuickPanel: View {
    @ObservedObject var model: QuickPanelModel
    let refresh: () -> Void
    let toggleFocus: () -> Void
    let toggleAlerts: () -> Void
    let openHistory: () -> Void
    let openSettings: () -> Void
    let openManagement: () -> Void
    let openAdvanced: () -> Void
    @State private var showDetails = false

    private var state: QuickPanelState { model.state }
    private func gib(_ bytes: UInt64) -> String {
        String(format: "%.2f GiB", Double(bytes) / 1_073_741_824)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NetGuard").font(.headline)
                        Text(state.networkName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新整理")
                    .accessibilityLabel("重新整理網路狀態")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("今日剩餘流量（本機估計）").font(.subheadline.weight(.semibold))
                    if let download = state.download, let upload = state.upload {
                        HStack(alignment: .top, spacing: 16) {
                            budget("下載", "arrow.down", download)
                            budget("上傳", "arrow.up", upload)
                        }
                        Text("依本機設定額度計算，非校方確認餘額。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("配額未確認").font(.title3.weight(.semibold))
                        Text("尚無可用的網路與配額資料。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text(state.speedText).font(.system(.subheadline, design: .monospaced))
                    .accessibilityLabel("即時流量速率 " + state.speedText)
                if state.throughput.count >= 2 {
                    LiveThroughputChart(points: state.throughput)
                } else {
                    Text("即時趨勢：等待連續採樣").font(.caption2).foregroundStyle(.secondary)
                }
                Text(state.diagnostic).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: Binding(get: { state.focusEnabled }, set: { _ in toggleFocus() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重要工作模式").font(.subheadline.weight(.medium))
                        Text("暫停額外探測，保留流量監控").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                DisclosureGroup("詳細資訊", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.forecast)
                        Text(state.provider)
                        Toggle("本機用量提醒", isOn: Binding(get: { state.alertsEnabled }, set: { _ in toggleAlerts() }))
                        Text("自動網路切換與程序控制尚未開放。").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 8)
                }
                Button("歷史流量與匯出", action: openHistory)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("網路管理與診斷", action: openManagement)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("設定", action: openSettings)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("返回舊版管理面板", action: openAdvanced)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380)
    }

    private func budget(_ label: String, _ symbol: String, _ item: QuickPanelBudget) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(gib(item.remaining)).font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            ProgressView(value: item.fraction)
                .accessibilityLabel(label + "本機估計用量")
                .accessibilityValue(String(format: "%.0f%%", item.fraction * 100))
            Text("已用 " + gib(item.used)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Both directions share one vertical scale. No extrapolation or synthetic zeroes.
struct LiveThroughputChart: View {
    let points: [ThroughputPoint]
    private var peak: Double {
        max(1, points.map { max($0.downloadBytesPerSecond, $0.uploadBytesPerSecond) }.max() ?? 1)
    }
    private func line(_ size: CGSize, upload: Bool) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last,
              last.uptime > first.uptime else { return path }
        let span = last.uptime - first.uptime
        for (index, point) in points.enumerated() {
            let rate = upload ? point.uploadBytesPerSecond : point.downloadBytesPerSecond
            let p = CGPoint(x: size.width * CGFloat((point.uptime - first.uptime) / span),
                            y: size.height * CGFloat(1 - rate / peak))
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("目前網卡 · 即時趨勢").font(.caption.weight(.medium))
                Spacer()
                Text(String(format: "峰值 %.2f MiB/s", peak / 1_048_576))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.10))
                    line(geometry.size, upload: false).stroke(Color.accentColor, lineWidth: 1.5)
                    line(geometry.size, upload: true).stroke(Color.teal, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                }
            }
            .frame(height: 44)
            .accessibilityHidden(true)
            HStack {
                Label("下載", systemImage: "line.diagonal").foregroundStyle(Color.accentColor)
                Label("上傳（虛線）", systemImage: "line.diagonal").foregroundStyle(Color.teal)
                Spacer()
                if let first = points.first, let last = points.last {
                    Text(String(format: "近 %.0f 秒", last.uptime - first.uptime))
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
