import Foundation

struct AntigravityLimit: Sendable {
    let groupName: String
    let name: String
    let remaining: Double
    let resetDate: Date?
}

struct AntigravityUsageClient {
    static var isInstalled: Bool {
        ["/Users/samjo/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func fetch() async throws -> [AntigravityLimit] {
        try await Task.detached(priority: .utility) { try Self.fetchSynchronously() }.value
    }

    private static func fetchSynchronously() throws -> [AntigravityLimit] {
        let executable = ["/Users/samjo/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { throw ClientError.executableNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "/usage", "--output-format", "json", "--print-timeout", "15s"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = envelope["command"] as? [String: Any],
              let commandData = command["data"] as? [String: Any],
              let groups = commandData["groups"] as? [[String: Any]] else { throw ClientError.invalidResponse }

        return groups.flatMap { group in
            let groupName = group["name"] as? String ?? "Antigravity"
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            return buckets.compactMap { bucket -> AntigravityLimit? in
                guard let name = bucket["name"] as? String,
                      let fraction = bucket["remaining_fraction"] as? NSNumber else { return nil }
                let reset = (bucket["reset_time"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                let label = (bucket["window"] as? String) == "weekly" ? "Weekly" : "5-hour"
                return AntigravityLimit(groupName: groupName, name: label, remaining: fraction.doubleValue, resetDate: reset)
            }
        }
    }

    private enum ClientError: Error { case executableNotFound, invalidResponse }
}
