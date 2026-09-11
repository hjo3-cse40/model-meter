import Darwin
import Foundation
import OSLog

struct CursorLimit: Sendable {
    let name: String
    let usedPercent: Double
    let resetDate: Date?
}

struct CursorUsageResult: Sendable {
    let limits: [CursorLimit]
    let status: String
}

struct CursorUsageClient {
    private static let agentPaths = [
        "/Users/samjo/.local/bin/agent",
        "/Users/samjo/.local/bin/cursor-agent",
        "/usr/local/bin/agent"
    ]
    private static let workingDirectory = URL(fileURLWithPath: "/tmp/ModelMeter-CursorCLI", isDirectory: true)
    private static let diagnosticsLogger = Logger(subsystem: "com.hjo3.modelmeter", category: "CursorUsage")

    func fetchResult() async -> CursorUsageResult {
        await Task.detached(priority: .utility) {
            do {
                let limits = try Self.fetchSynchronously()
                return CursorUsageResult(limits: limits, status: "Connected")
            } catch ClientError.notInstalled {
                return CursorUsageResult(limits: [], status: "Install Cursor Agent CLI")
            } catch ClientError.authenticationRequired {
                return CursorUsageResult(limits: [], status: "Sign in to Cursor Agent CLI")
            } catch ClientError.workspaceTrustRequired {
                return CursorUsageResult(limits: [], status: "Cursor workspace trust required")
            } catch {
                return CursorUsageResult(limits: [], status: "Cursor CLI unavailable")
            }
        }.value
    }

    private static func fetchSynchronously() throws -> [CursorLimit] {
        guard let agent = agentPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ClientError.notInstalled
        }

        try prepareWorkingDirectory()

        let input = Pipe()
        let output = Pipe()
        let capture = CaptureBuffer()
        let outputStarted = DispatchSemaphore(value: 0)
        let terminalEvent = DispatchSemaphore(value: 0)
        let terminated = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // macOS `script` takes the command and its arguments separately; it
        // does not support the GNU `-c` form.
        // `script` inherits no usable window size when its own standard input
        // is a pipe. Set the child PTY geometry before starting Cursor;
        // otherwise Ink renders the prompt one character per row.
        process.arguments = [
            "-q", "/dev/null",
            "/bin/sh", "-c",
            "/bin/stty rows 40 columns 120; exec \"$@\"",
            "model-meter-cursor", agent, "--trust"
        ]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["COLUMNS"] = "120"
        environment["LINES"] = "40"
        process.environment = environment

        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            capture.append(chunk)
            outputStarted.signal()

            let text = Self.stripANSI(String(decoding: capture.snapshot(), as: UTF8.self))
            if Self.usagePanelFound(in: text) || Self.authenticationRequested(in: text) || Self.workspaceTrustRequested(in: text) {
                terminalEvent.signal()
            }
        }
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
            diagnose("launch_error=none pid=\(process.processIdentifier) cwd=/tmp/ModelMeter-CursorCLI")
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            diagnose("launch_error=\(sanitizeForDiagnostics(String(describing: error)))")
            throw ClientError.launchFailed
        }

        // Wait for the CLI to begin painting its TUI. If startup is silent,
        // still submit after the bounded wait so this provider cannot hang the
        // other refreshes.
        _ = outputStarted.wait(timeout: .now() + 8)
        Thread.sleep(forTimeInterval: 0.2)

        var usageSubmitted = false
        if process.isRunning {
            // Send typing and Return as separate terminal input events. Ink's
            // prompt treats a combined `/usage\r` write as pasted text and
            // leaves the slash command selected without opening it.
            input.fileHandleForWriting.write(Data("/usage".utf8))
            Thread.sleep(forTimeInterval: 0.3)
            input.fileHandleForWriting.write(Data("\r".utf8))
            usageSubmitted = true
        }

        _ = terminalEvent.wait(timeout: .now() + 15)

        // Ask the pager to close, interrupt the agent, and close stdin. Then
        // force-stop `script` if it ignores termination so waitUntilExit can
        // never strand the provider refresh.
        if process.isRunning {
            input.fileHandleForWriting.write(Data([0x1B, 0x03]))
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = terminated.wait(timeout: .now() + 2)
        }

        output.fileHandleForReading.readabilityHandler = nil
        let text = stripANSI(String(decoding: capture.snapshot(), as: UTF8.self))
        let authenticationRequested = authenticationRequested(in: text)
        let workspaceTrustRequested = workspaceTrustRequested(in: text)
        let usageEchoed = text.contains("/usage")
        let usagePanelFound = usagePanelFound(in: text)
        let terminationStatus = process.isRunning ? "still-running" : String(process.terminationStatus)

        diagnose("termination_status=\(terminationStatus)")
        diagnose("usage_submitted=\(usageSubmitted) usage_echoed=\(usageEchoed) usage_panel_received=\(usagePanelFound)")
        diagnose("authentication_requested=\(authenticationRequested) workspace_trust_requested=\(workspaceTrustRequested)")
        diagnose("captured_output=\(sanitizeForDiagnostics(text))")

        if authenticationRequested {
            throw ClientError.authenticationRequired
        }
        if workspaceTrustRequested { throw ClientError.workspaceTrustRequired }

        let resetDate = parseResetDate(from: text)
        let limits: [CursorLimit] = ["Included", "Auto", "API"].compactMap { name in
            guard let used = percentage(for: name, in: text) else { return nil }
            return CursorLimit(name: name, usedPercent: used, resetDate: resetDate)
        }
        guard limits.count == 3 else { throw ClientError.usageNotFound }
        return limits
    }

    private static func percentage(for label: String, in text: String) -> Double? {
        let escapedLabel = NSRegularExpression.escapedPattern(for: label)
        let pattern = "(?im)\\b" + escapedLabel + "\\b[^\\r\\n\\d]{0,80}(\\d{1,3})\\s*%\\s*used"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range])
    }

    private static func usagePanelFound(in text: String) -> Bool {
        ["Included", "Auto", "API"].allSatisfy { percentage(for: $0, in: text) != nil }
    }

    private static func authenticationRequested(in text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("authentication required") ||
            normalized.contains("run 'agent login'") ||
            normalized.contains("run \"agent login\"") ||
            normalized.contains("login failed") ||
            normalized.contains("log in to cursor") ||
            normalized.contains("sign in to cursor")
    }

    private static func workspaceTrustRequested(in text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("trust this workspace") ||
            normalized.contains("workspace trust") ||
            normalized.contains("do you trust")
    }

    private static func prepareWorkingDirectory() throws {
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: nil
        )
        guard contents.isEmpty else { throw ClientError.workingDirectoryNotEmpty }
    }

    private static func parseResetDate(from text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"Resets ([A-Z][a-z]{2} \d{1,2})"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        let year = Calendar.current.component(.year, from: Date())
        guard let date = formatter.date(from: "\(text[range]) \(year)") else { return nil }
        return date < Date() ? Calendar.current.date(byAdding: .year, value: 1, to: date) : date
    }

    private static func stripANSI(_ text: String) -> String {
        var result = text
        let patterns = [
            "\u{001B}\\][^\u{0007}]*(?:\u{0007}|\u{001B}\\\\)",
            "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            "\u{001B}[()][A-Z0-9]"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        return result
    }

    private static func sanitizeForDiagnostics(_ text: String) -> String {
        var result = text
        let replacements = [
            (#"https?://\S+"#, "[URL REDACTED]"),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[EMAIL REDACTED]"),
            (#"/Users/[^\s]+"#, "[HOME PATH REDACTED]"),
            (#"\b[A-Za-z0-9_-]{32,}\b"#, "[TOKEN REDACTED]")
        ]
        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }
        result = String(result.unicodeScalars.map { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value >= 0x20 ? Character(String(scalar)) : "?"
        })
        if result.count > 6_000 {
            result = "[TRUNCATED]…" + String(result.suffix(6_000))
        }
        return result.replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func diagnose(_ message: String) {
#if DEBUG
        diagnosticsLogger.notice("\(message, privacy: .public)")
#endif
    }

    private final class CaptureBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard data.count < 1_000_000 else { return }
            data.append(chunk.prefix(1_000_000 - data.count))
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private enum ClientError: Error {
        case notInstalled
        case authenticationRequired
        case workspaceTrustRequired
        case workingDirectoryNotEmpty
        case launchFailed
        case usageNotFound
    }
}
