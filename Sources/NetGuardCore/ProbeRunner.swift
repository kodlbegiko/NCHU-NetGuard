import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ProbeOutcome: Equatable, Sendable {
    case success(String), failed, timedOut, outputLimit
}

/// Read-only probes with a bounded in-memory pipe, no disk spooling and no shell.
/// A timeout stops collecting output and requests termination of our own child.
/// A non-cooperative child/descendant can outlive the deadline; no process-tree kill.
enum ProbeRunner {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5,
                    maxBytes: Int = 1_048_576, acceptedExitCodes: Set<Int32> = [0]) -> ProbeOutcome {
        guard path.hasPrefix("/"), timeout.isFinite, timeout > 0, timeout <= 30,
              (1...4_194_304).contains(maxBytes) else { return .failed }
        let pipe = Pipe()
        let input = pipe.fileHandleForReading
        defer { try? input.close(); try? pipe.fileHandleForWriting.close() }
        let fd = input.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return .failed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let start = ProcessInfo.processInfo.systemUptime
        do { try process.run() } catch { return .failed }
        // Close the parent's write end; an EOF reflects all inherited writers.
        try? pipe.fileHandleForWriting.close()
        func stop(_ outcome: ProbeOutcome) -> ProbeOutcome {
            if process.isRunning { process.terminate() }
            return outcome
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, maxBytes + 1))
        var eof = false
        while true {
            if ProcessInfo.processInfo.systemUptime - start >= timeout { return stop(.timedOut) }
            if !eof {
                let requested = min(buffer.count, maxBytes + 1 - output.count)
                let n = buffer.withUnsafeMutableBytes { raw in
                    read(fd, raw.baseAddress, requested)
                }
                if n > 0 {
                    output.append(contentsOf: buffer.prefix(n))
                    guard output.count <= maxBytes else { return stop(.outputLimit) }
                    continue
                }
                if n == 0 { eof = true }
                else if errno == EINTR { continue }
                else if errno != EAGAIN && errno != EWOULDBLOCK { return stop(.failed) }
            }
            if eof && !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.terminationReason == .exit, acceptedExitCodes.contains(process.terminationStatus),
              let text = String(data: output, encoding: .utf8) else { return .failed }
        return .success(text)
    }
}
