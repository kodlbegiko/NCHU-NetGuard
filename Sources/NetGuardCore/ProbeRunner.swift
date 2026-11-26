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
package enum ProbeRunner {
    /// All production calls pass this argument policy. The low-level pipe
    /// runner remains separately testable with synthetic fixture commands.
    package static func isApproved(_ path: String, _ arguments: [String]) -> Bool {
        guard arguments.count <= 16, arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 4096 }) else { return false }
        func numeric(_ literal: String, ipv6: Bool) -> Bool {
            if ipv6 {
                var value = in6_addr()
                return inet_pton(AF_INET6, literal, &value) == 1
            }
            var value = in_addr()
            return inet_pton(AF_INET, literal, &value) == 1
        }
        switch path {
        case "/sbin/route":
            guard arguments.count == 4, arguments[0] == "-n", arguments[1] == "get",
                  ["-inet", "-inet6"].contains(arguments[2]) else { return false }
            return arguments[3] == "default" || numeric(arguments[3], ipv6: arguments[2] == "-inet6")
        case "/usr/sbin/ipconfig":
            guard arguments.count == 2, arguments[0] == "getifaddr" else { return false }
            let name = arguments[1]
            return (1...32).contains(name.utf8.count) && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            }
        case "/bin/ps":
            return arguments == ["-ax", "-o", "pid=,ppid=,lstart=,comm="]
        case "/usr/bin/nettop":
            return arguments == ["-P", "-L", "1", "-J", "bytes_in,bytes_out"] ||
                ["tcp", "udp"].contains { mode in
                    arguments == ["-m", mode, "-n", "-x", "-L", "1", "-J", "bytes_in,bytes_out,interface,state"]
                }
        case "/sbin/ping":
            return arguments.count == 5 && Array(arguments.prefix(4)) == ["-c", "2", "-t", "3"] &&
                ["140.120.1.2", "1.1.1.1"].contains(arguments[4])
        case "/usr/bin/dig":
            return arguments == ["-r", "+time=2", "+tries=1", "+noall", "+comments", "+stats", "example.com.", "A"]
        case "/usr/bin/osascript":
            return arguments.count == 9 && Array(arguments.prefix(7)) == ["-e", "on run argv", "-e",
                "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", "--"] &&
                arguments[7].utf8.count <= 1024
        case "/usr/bin/python3":
            guard arguments.count == 2, arguments[1] == "--json",
                  let resource = Bundle.main.url(forResource: "traffic_monitor", withExtension: "py"),
                  let directory = Bundle.main.resourceURL,
                  arguments[0] == resource.path else { return false }
            return resource.resolvingSymlinksInPath().deletingLastPathComponent().path ==
                directory.resolvingSymlinksInPath().path
        default: return false
        }
    }

    package static func runApproved(_ path: String, _ arguments: [String], timeout: TimeInterval = 5,
                    maxBytes: Int = 1_048_576, acceptedExitCodes: Set<Int32> = [0]) -> ProbeOutcome {
        guard isApproved(path, arguments) else { return .failed }
        // Python ignores environment/user-site module injection.
        return run(path, path == "/usr/bin/python3" ? ["-I"] + arguments : arguments,
                   timeout: timeout, maxBytes: maxBytes, acceptedExitCodes: acceptedExitCodes)
    }

    /// Only the fixed default-route query retains stderr. This is bounded by
    /// the same output cap; unrelated probes keep discarding diagnostics.
    package static func runDefaultRoute(ipv6: Bool) -> ProbeOutcome {
        let arguments = ["-n", "get", ipv6 ? "-inet6" : "-inet", "default"]
        guard isApproved("/sbin/route", arguments) else { return .failed }
        return run("/sbin/route", arguments, timeout: 2, maxBytes: 65_536,
                   mergeStandardError: true)
    }

    package static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5,
                    maxBytes: Int = 1_048_576, acceptedExitCodes: Set<Int32> = [0],
                    mergeStandardError: Bool = false) -> ProbeOutcome {
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
        process.standardError = mergeStandardError ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
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
