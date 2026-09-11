import ApplicationServices
import AppKit
import Foundation

struct CursorLimit: Sendable {
    let name: String
    let usedPercent: Double
    let resetDate: Date?
}

struct CursorUsageClient {
    func fetch() async throws -> [CursorLimit] {
        try await Task.detached(priority: .utility) { try Self.fetchSynchronously() }.value
    }

    private static func fetchSynchronously() throws -> [CursorLimit] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == "Cursor" || $0.bundleIdentifier?.localizedCaseInsensitiveContains("cursor") == true
        }) else { throw ClientError.appNotRunning }

        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        guard trusted else { throw ClientError.accessibilityNotGranted }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var values: [String] = []
        collectText(from: root, into: &values, depth: 0)
        let pageText = values.joined(separator: "\n")
        let resetDate = parseResetDate(from: pageText)

        return ["Cursor Models", "Other Models"].compactMap { name in
            guard let used = firstPercentage(after: name, in: pageText) else { return nil }
            return CursorLimit(name: name, usedPercent: used, resetDate: resetDate)
        }
    }

    private static func collectText(from element: AXUIElement, into values: inout [String], depth: Int) {
        guard depth < 12 else { return }
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(text)
            }
        }

        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let childElements = children as? [AXUIElement] else { return }
        for child in childElements { collectText(from: child, into: &values, depth: depth + 1) }
    }

    private static func firstPercentage(after label: String, in text: String) -> Double? {
        guard let labelRange = text.range(of: label, options: .caseInsensitive) else { return nil }
        let suffix = String(text[labelRange.upperBound...].prefix(400))
        let pattern = #"(\d{1,3})\s*%\s*used"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)),
              let range = Range(match.range(at: 1), in: suffix) else { return nil }
        return Double(suffix[range])
    }

    private static func parseResetDate(from text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"reset on ([A-Z][a-z]{2} \d{1,2})"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        let year = Calendar.current.component(.year, from: Date())
        let date = formatter.date(from: "\(text[range]) \(year)")
        guard let date else { return nil }
        return date < Date() ? Calendar.current.date(byAdding: .year, value: 1, to: date) : date
    }

    private enum ClientError: Error { case appNotRunning, accessibilityNotGranted }
}
