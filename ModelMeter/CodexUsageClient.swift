import Foundation

struct CodexLimit: Sendable {
    let name: String
    let usedPercent: Double
    let resetDate: Date?
}

struct CodexUsageClient {
    func fetch() async throws -> [CodexLimit] {
        try await Task.detached(priority: .utility) {
            try Self.fetchSynchronously()
        }.value
    }

    private static func fetchSynchronously() throws -> [CodexLimit] {
        let process = Process()
        let executable = ["/Users/samjo/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { throw ClientError.executableNotFound }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        let initialize = "{\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"model-meter\",\"title\":\"Model Meter\",\"version\":\"0.1.0\"}}}\n"
        let initialized = "{\"method\":\"initialized\",\"params\":{}}\n"
        let request = "{\"method\":\"account/rateLimits/read\",\"id\":2,\"params\":{}}\n"
        input.fileHandleForWriting.write(Data((initialize + initialized + request).utf8))

        let readGroup = DispatchGroup()
        readGroup.enter()
        var responseData = Data()
        DispatchQueue.global(qos: .utility).async {
            responseData = output.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        _ = readGroup.wait(timeout: .now() + 8)
        process.terminate()
        _ = readGroup.wait(timeout: .now() + 1)

        let responseLine = String(data: responseData, encoding: .utf8)?
            .split(separator: "\n")
            .last(where: { $0.contains("\"id\":2") && $0.contains("\"result\"") })
        guard let responseLine,
              let object = try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any] else { throw ClientError.invalidResponse }
        let buckets = (result["rateLimitsByLimitId"] as? [String: Any]) ?? [:]
        let source = buckets["codex"] as? [String: Any] ?? (result["rateLimits"] as? [String: Any] ?? [:])
        return ["primary", "secondary"].compactMap { key in
            guard let bucket = source[key] as? [String: Any], let used = bucket["usedPercent"] as? NSNumber else { return nil }
            let duration = (bucket["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let name = duration >= 10_000 ? "Weekly" : duration >= 240 ? "5-hour" : duration > 0 ? "(duration)m window" : key.capitalized
            let reset = (bucket["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexLimit(name: name, usedPercent: used.doubleValue, resetDate: reset)
        }
    }

    private enum ClientError: Error { case executableNotFound, invalidResponse }
}
