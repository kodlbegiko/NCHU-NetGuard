import Cocoa
import SwiftUI
import Foundation

/// Explicit fixture-only launch path. Never constructs the production
/// delegate, reads its preferences/history, starts probes, or invokes actions.
final class NetGuardSmokeDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var status: NSStatusItem?

    private func fail(_ stage: String) -> Never {
        FileHandle.standardError.write(Data(("NETGUARD_SMOKE_FAIL " + stage + "\n").utf8))
        exit(1)
    }

    private func host<V: View>(_ root: V, title: String, width: CGFloat, height: CGFloat) {
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Explicit window and hosting-view geometry before asynchronous layout.
        // NSHostingController may initially report a zero-sized SwiftUI view.
        window.setContentSize(NSSize(width: width, height: height))
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.orderFront(nil)
        windows.append(window)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Bundle.main.url(forResource: "popover", withExtension: "html") != nil,
              Bundle.main.url(forResource: "traffic_monitor", withExtension: "py") != nil
        else { fail("bundle resources") }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { fail("status item") }
        button.title = "NetGuard Smoke"
        status = item

        let quick = QuickPanelModel()
        host(QuickPanel(model: quick, refresh: {}, toggleFocus: {}, toggleAlerts: {},
            openHistory: {}, openSettings: {}, openManagement: {}, openAdvanced: {}),
            title: "Smoke · Quick panel", width: 380, height: 570)

        let settings = NetGuardSettingsModel()
        host(NetGuardSettingsView(model: settings, setAlerts: { _ in }, setFocus: { _ in },
            setNativePreview: { _ in }, setDisplayMode: { _ in }, setRateUnit: { _ in },
            saveBudget: { _, _ in }, clearBudget: {}, createBackup: {}, inspectBackup: {},
            createBundle: {}, inspectBundle: {}, recoverBundle: {}),
            title: "Smoke · Settings", width: 500, height: 540)

        let management = ManagementModel()
        management.snapshot = ManagementSnapshot(scopes: ["en0": .external],
            defaultInterface: "en0", connectionKnown: true, latencyStatus: "Fixture",
            processRows: [], processAge: nil, focusEnabled: false,
            diagnosticInput: DiagnosticInput(connected: true, scope: .external,
                persistenceHealthy: true, sampleGapCount: 0, providerFresh: false),
            providerStatus: "Fixture")
        management.automation = AutomationSnapshot(alertsEnabled: false, focusEnabled: false,
            sleeping: false, assessment: nil, ledger: QuotaAlertLedger(),
            day: "2026-11-25", ledgerStatus: "Fixture")
        host(ManagementView(model: management, refresh: {}, openProvider: {},
            setAlerts: { _ in }, setFocus: { _ in }, setHistoryEnabled: { _ in },
            setProcessBackground: { _ in }, reloadHistory: {}, testDNS: {}, measureFlow: { _ in },
            configureTrafficEvents: { _ in }, setEventNotifications: { _ in }, saveEventArchive: {}, loadEventArchive: {},
            clearEventArchive: {}, clearTrafficEvents: {}, startConnectionSession: { _, _ in },
            stopConnectionSession: {}, saveConnectionArchive: {}, loadConnectionArchive: {},
            deleteConnectionArchive: { _ in }, setHistoryRetention: { _ in }, deleteHistory: {}),
            title: "Smoke · Management", width: 540, height: 510)

        guard let row = try? HistoryDay(day: "2026-11-24", total: 15, download: 10, upload: 5) else {
            fail("history fixture")
        }
        host(HistoryAnalyticsView(records: [row], scopedRecords: [:], today: "2026-11-25", storageHealthy: true),
            title: "Smoke · History", width: 560, height: 560)

        // Give AppKit and SwiftUI a run-loop turn to lay out hosted content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.windows.count == 4, self.status?.button != nil else {
                self?.fail("window lifetime")
                exit(1)
            }
            for window in self.windows {
                guard let view = window.contentView, let controller = window.contentViewController else {
                    self.fail("missing window content: " + window.title)
                }
                view.layoutSubtreeIfNeeded()
                controller.view.layoutSubtreeIfNeeded()
                guard view.bounds.width > 0, view.bounds.height > 0,
                      controller.view.bounds.width > 0, controller.view.bounds.height > 0 else {
                    self.fail("window layout: " + window.title)
                }
                window.orderOut(nil)
            }
            if let item = self.status { NSStatusBar.system.removeStatusItem(item) }
            self.status = nil
            self.windows.removeAll()
            FileHandle.standardOutput.write(Data("NETGUARD_SMOKE_OK fixture-native-views=4 status-item=1 resources=2\n".utf8))
            NSApplication.shared.terminate(nil)
        }
    }
}
