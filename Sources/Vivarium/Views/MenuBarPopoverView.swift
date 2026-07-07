import SwiftUI
import VivariumCore

/// The menu bar icon. Shows an active/idle fish glyph plus a count when more than one agent swims,
/// with an optional gentle 1 Hz pulse (off by default) while agents are active.
struct MenuBarLabel: View {
    let store: VivariumStore
    let settings: SettingsStore

    var body: some View {
        if settings.menuBarAnimation && store.hasActiveAgents {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                content(opacity: pulse(at: context.date))
            }
        } else {
            content(opacity: 1)
        }
    }

    @ViewBuilder
    private func content(opacity: Double) -> some View {
        let count = store.activeFishCount
        HStack(spacing: 2) {
            Image(systemName: store.hasActiveAgents ? "fish.fill" : "fish")
                .opacity(opacity)
            if count > 1 {
                Text("\(count)")
            }
        }
    }

    private func pulse(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return 0.55 + 0.45 * (0.5 + 0.5 * sin(t * .pi))
    }
}

/// The `.window`-style popover: header summary, a live list of fish, and the action footer.
struct MenuBarPopoverView: View {
    let store: VivariumStore
    let onOpenAquarium: () -> Void

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fishList
            Divider()
            footer
        }
        .frame(width: 326)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Vivarium")
                    .font(.headline)
                DataSourcePill(mode: store.dataSourceMode)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.teal)
                    .imageScale(.small)
                Text(store.state.reefStage.displayName)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
                Text("\(store.state.totalTasksCompleted) done")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Fish list

    @ViewBuilder
    private var fishList: some View {
        if store.state.fish.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.state.fish) { fish in
                        FishRow(fish: fish)
                        if fish.id != store.state.fish.last?.id {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "fish")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("No agents swimming yet")
                .font(.subheadline.weight(.medium))
            Text("Start a Claude Code or Codex session to bring the reef to life.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            achievementsSummary

            Button(action: onOpenAquarium) {
                Label("Open Aquarium", systemImage: "water.waves")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 8) {
                Button {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var achievementsSummary: some View {
        let achievements = store.state.achievements
        HStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(achievements.isEmpty ? Color.secondary : .yellow)
                .imageScale(.small)
            if let latest = achievements.last {
                Text(latest.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(achievements.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("No achievements yet")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rows & pills

private struct DataSourcePill: View {
    let mode: DataSourceMode

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var label: String {
        switch mode {
        case .live: "Live"
        case .idle: "Idle"
        case .demo: "Demo"
        }
    }

    private var tint: Color {
        switch mode {
        case .live: .green
        case .idle: .gray
        case .demo: .blue
        }
    }
}

private struct FishRow: View {
    let fish: FishState

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: fish.provider)

            VStack(alignment: .leading, spacing: 3) {
                Text(fish.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(fish.status.humanized)
                    .font(.caption)
                    .foregroundStyle(fish.status.isActive ? .primary : .secondary)
                    .lineLimit(1)
                FatigueBar(value: fish.fatigue)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct ProviderBadge: View {
    let provider: AgentProvider

    var body: some View {
        Circle()
            .fill(provider.tint.gradient)
            .frame(width: 32, height: 32)
            .overlay(
                Text(provider.shortCode)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            )
    }
}

private struct FatigueBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * clamped))
            }
        }
        .frame(height: 3)
    }

    private var tint: Color {
        switch value {
        case ..<0.4: .green
        case ..<0.75: .yellow
        default: .orange
        }
    }
}

// MARK: - Display helpers

extension AgentProvider {
    var tint: Color {
        switch self {
        case .claude: .teal
        case .codex: .orange
        case .gemini: .purple
        case .cursor: .pink
        case .gpt: .blue
        }
    }

    var shortCode: String {
        switch self {
        case .claude: "Cl"
        case .codex: "Cx"
        case .gemini: "Gm"
        case .cursor: "Cu"
        case .gpt: "G"
        }
    }
}

extension AgentStatus {
    /// Human-facing present-tense phrasing for the popover.
    var humanized: String {
        switch self {
        case .searching: "Searching…"
        case .planning: "Planning…"
        case .coding: "Editing…"
        case .reviewing: "Reviewing…"
        case .testing: "Running tests…"
        case .fixingBug: "Fixing a bug…"
        case .handingOff: "Handing off…"
        case .waiting: "Waiting for you"
        case .resting: "Resting"
        case .celebrating: "Celebrating!"
        }
    }
}

extension ReefStage {
    var displayName: String {
        switch self {
        case .sand: "Sandy Bottom"
        case .coral: "Coral Reef"
        case .shells: "Shell Bed"
        case .seaweed: "Kelp Forest"
        case .tropicalFish: "Tropical Waters"
        case .grandAquarium: "Grand Aquarium"
        }
    }
}
