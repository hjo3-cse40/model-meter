import SwiftUI

enum ProviderKind: String, CaseIterable {
    case codex = "OpenAI Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case antigravity = "Antigravity"
}

struct UsageWindow: Identifiable {
    let id = UUID()
    let name: String
    let remaining: Double?
    let resetDate: Date?
    let detail: String?
    let tint: Color

    var remainingText: String {
        guard let remaining else { return "Unavailable" }
        return "\(Int(remaining * 100))% remaining"
    }

    var resetText: String {
        guard let resetDate else { return detail ?? "Not connected" }
        let seconds = max(0, Int(resetDate.timeIntervalSinceNow))
        if seconds < 3600 { return "Resets in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "Resets in \(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "Resets \(resetDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

struct ProviderUsage: Identifiable {
    let id: ProviderKind
    let name: String
    let color: Color
    let windows: [UsageWindow]
    let status: String

    var summary: String {
        let values = windows.compactMap(\.remaining)
        guard let minimum = values.min() else { return status }
        return "\(Int(minimum * 100))% left"
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var providers: [ProviderUsage] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isRefreshing = false
    private var timer: Timer?

    init() {
        providers = Self.unavailableProviders()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var menuBarTitle: String {
        providers.map { provider in
            let short = provider.id == .codex ? "O" : provider.id == .claude ? "H" : provider.id == .cursor ? "C" : "A"
            let value = provider.windows.compactMap(\.remaining).min().map { String(Int($0 * 100)) } ?? "—"
            return "\(short) \(value)"
        }.joined(separator: " · ")
    }

    var menuBarColor: Color {
        let minimum = providers.flatMap { $0.windows.compactMap(\.remaining) }.min()
        return minimum.map { $0 < 0.2 ? .orange : .green } ?? .secondary
    }

    var updatedText: String {
        guard let lastUpdated else { return "Not connected" }
        return "Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))"
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let codexTask = Self.fetchCodex()
        async let antigravityTask = Self.fetchAntigravity()
        let codexLimits = await codexTask
        let antigravityLimits = await antigravityTask
        providers = Self.providers(codex: codexLimits, antigravity: antigravityLimits)
        if !codexLimits.isEmpty || !antigravityLimits.isEmpty { lastUpdated = Date() }
    }

    private static func fetchCodex() async -> [CodexLimit] {
        (try? await CodexUsageClient().fetch()) ?? []
    }

    private static func fetchAntigravity() async -> [AntigravityLimit] {
        (try? await AntigravityUsageClient().fetch()) ?? []
    }

    private static func providers(codex: [CodexLimit], antigravity: [AntigravityLimit]) -> [ProviderUsage] {
        let codexWindows = codex.map { limit in
            UsageWindow(name: limit.name, remaining: max(0, 1 - limit.usedPercent / 100), resetDate: limit.resetDate, detail: nil, tint: .teal)
        }
        let agWindows = antigravity.map { limit in
            UsageWindow(name: "\(limit.groupName) · \(limit.name)", remaining: limit.remaining, resetDate: limit.resetDate, detail: nil, tint: .purple)
        }
        let allProviders = [
            ProviderUsage(id: .codex, name: ProviderKind.codex.rawValue, color: .teal, windows: codexWindows.isEmpty ? unavailableWindows("Usage unavailable") : codexWindows, status: codexWindows.isEmpty ? "Usage unavailable" : "Connected"),
            unavailable(kind: .claude),
            unavailable(kind: .cursor, status: "Dashboard only"),
            ProviderUsage(id: .antigravity, name: ProviderKind.antigravity.rawValue, color: .purple, windows: agWindows.isEmpty ? unavailableWindows(AntigravityUsageClient.isInstalled ? "Usage unavailable" : "Install agy CLI") : agWindows, status: agWindows.isEmpty ? "Usage unavailable" : "Connected")
        ]
        return allProviders.enumerated().sorted { lhs, rhs in
            let lhsConnected = lhs.element.windows.contains { $0.remaining != nil }
            let rhsConnected = rhs.element.windows.contains { $0.remaining != nil }
            if lhsConnected != rhsConnected { return lhsConnected }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func unavailableProviders() -> [ProviderUsage] {
        [unavailable(kind: .codex, status: "Connecting…"), unavailable(kind: .claude), unavailable(kind: .cursor, status: "Dashboard only"), unavailable(kind: .antigravity)]
    }

    private static func unavailable(kind: ProviderKind, status: String = "Not connected") -> ProviderUsage {
        let color: Color = switch kind { case .codex: .teal; case .claude: .orange; case .cursor: .blue; case .antigravity: .purple }
        return ProviderUsage(id: kind, name: kind.rawValue, color: color, windows: unavailableWindows(status, tint: color), status: status)
    }

    private static func unavailableWindows(_ text: String, tint: Color = .gray) -> [UsageWindow] {
        [UsageWindow(name: "Usage", remaining: nil, resetDate: nil, detail: text, tint: tint)]
    }
}
