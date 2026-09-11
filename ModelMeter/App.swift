import ServiceManagement
import SwiftUI

@main
struct ModelMeterApp: App {
    @StateObject private var model = UsageViewModel()
    @State private var launchAtLogin = false

    var body: some Scene {
        MenuBarExtra {
            UsagePopover(model: model, launchAtLogin: $launchAtLogin)
                .padding(12)
                .frame(width: 300)
                .onAppear {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                    Task { await model.refresh() }
                }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(model.menuBarColor).frame(width: 7, height: 7)
                Text(model.menuBarTitle).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

struct UsagePopover: View {
    @ObservedObject var model: UsageViewModel
    @Binding var launchAtLogin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Usage").font(.title3.weight(.semibold))
                Spacer()
                Text(model.updatedText).font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.providers) { provider in
                ProviderCard(provider: provider)
            }

            Divider()

            HStack {
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        launchAtLogin = value
                        try? value ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model Meter AI usage")
    }
}

struct ProviderCard: View {
    let provider: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProviderLogo(kind: provider.id, color: provider.color)
                Text(provider.name).font(.headline)
                Spacer()
                Text(provider.summary).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }

            ForEach(provider.windows) { window in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(window.name).font(.caption)
                        Spacer()
                        Text(window.remainingText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    ProgressView(value: window.remaining)
                        .tint(window.tint)
                    Text(window.resetText).font(.caption2).foregroundStyle(.secondary)
                }
            }

        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.name), \(provider.summary)")
    }
}

/// Compact provider marks for the popover. These deliberately do not appear in
/// the status item's label: that label is kept narrow so it remains useful when
/// macOS needs menu-bar space for system indicators such as microphone access.
struct ProviderLogo: View {
    let kind: ProviderKind
    let color: Color

    private var assetName: String {
        switch kind {
        case .codex: "ProviderCodex"
        case .cursor: "ProviderCursor"
        case .antigravity: "ProviderGemini"
        case .claude: "ProviderClaude"
        }
    }

    var body: some View {
        Image(assetName)
            .resizable()
            .renderingMode(kind == .codex ? .template : .original)
            .foregroundStyle(color)
            .scaledToFit()
            .padding(3)
            .frame(width: 22, height: 22)
            // The card combines its children into one useful provider-and-usage
            // announcement, so exposing this decorative mark separately would
            // make VoiceOver repeat the provider name.
            .accessibilityHidden(true)
    }
}
