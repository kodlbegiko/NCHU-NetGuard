import Foundation

public enum ProbeOutcome: Equatable, Sendable {
    case success(String), failed, timedOut, outputLimit
}

/// Fixed executable and argv; no shell. Intended for short, read-only probes.
/// Only this runner's own child may be terminated. A non-cooperative child
/// can outlive the deadline; no guarantee of forced process-tree termination.
enum ProbeRunner {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5,
                    maxBytes: Int = 1_048_576) -> ProbeOutcome {
        guard path.hasPrefix("/"), timeout.isFinite, timeout > 0, timeout <= 30,
              (1...4_194_304).contains(maxBytes) else { return .failed }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("stdout")
            guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else { return .failed }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            try process.run()
            let start = ProcessInfo.processInfo.systemUptime
            while process.isRunning {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > maxBytes {
                    if process.isRunning { process.terminate() }
                    return .outputLimit
                }
                if ProcessInfo.processInfo.systemUptime - start >= timeout {
                    if process.isRunning { process.terminate() }
                    return .timedOut
                }
                Thread.sleep(forTimeInterval: 0.025)
            }
            guard process.terminationStatus == 0 else { return .failed }
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            let bytes = try reader.read(upToCount: maxBytes + 1) ?? Data()
            guard bytes.count <= maxBytes else { return .outputLimit }
            guard let output = String(data: bytes, encoding: .utf8) else { return .failed }
            return .success(output)
        } catch { return .failed }
    }
}
