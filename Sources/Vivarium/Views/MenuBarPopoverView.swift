import SwiftUI
import VivariumCore

/// The menu bar popover: header summary, a live list of fish, and the action footer.
/// Styled to the "Shoal" design — dark translucent surface, reef progress, status pills.
struct MenuBarPopoverView: View {
    let store: VivariumStore
    let onOpenAquarium: () -> Void
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = { NSApp.terminate(nil) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            fishList
            Divider().overlay(Color.white.opacity(0.1))
            footer
        }
        .frame(width: 340)
        .background(Color(.sRGB, red: 0.173, green: 0.176, blue: 0.196, opacity: 1)) // #2C2D32 dark card
        .environment(\.colorScheme, .dark)
        .onAppear { DebugTrace.log("MenuBarPopover APPEARED fish=\(store.state.fish.count)") }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Vivarium")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                headerPill
                Spacer(minLength: 0)
                Text(store.state.ambient.phase.lightingLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            reefProgress
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    /// Data-source indicator: Demo / Idle badge, or a green "N active" (Live) pill.
    @ViewBuilder
    private var headerPill: some View {
        switch store.dataSourceMode {
        case .demo:
            HeaderPill(label: "Demo", color: Color(.sRGB, red: 0.36, green: 0.60, blue: 0.95, opacity: 1))
        case .idle:
            HeaderPill(label: "Idle", color: .gray, showDot: false)
        case .live:
            HeaderPill(
                label: store.activeFishCount > 0 ? "\(store.activeFishCount) active" : "Live",
                color: Shoal.active
            )
        }
    }

    @ViewBuilder
    private var reefProgress: some View {
        let stage = store.state.reefStage
        let completed = store.state.totalTasksCompleted
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(stage.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Shoal.reefAccent)
                Spacer(minLength: 0)
                Text(stage.next.map { "\(completed) / \($0.threshold) → \($0.displayName)" } ?? "\(completed) tasks")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            let fraction: Double = stage.next.map { min(1, Double(completed) / Double(max(1, $0.threshold))) } ?? 1
            ProgressCapsule(fraction: fraction, fill: Shoal.reefGradient)
        }
    }

    // MARK: - Fish list

    /// Only agents that are currently running — idle/resting fish are hidden from the list even
    /// while they linger in the tank.
    private var runningFish: [FishState] {
        store.state.fish.filter { $0.status != .resting }
    }

    @ViewBuilder
    private var fishList: some View {
        let fish = runningFish
        if fish.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(fish) { item in
                        FishRow(fish: item)
                        if item.id != fish.last?.id {
                            Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 60)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 316)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "fish")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.4))
            Text("No agents swimming yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("Start a Claude Code or Codex session to bring the reef to life.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 34)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            Button(action: onOpenAquarium) {
                HStack(spacing: 6) {
                    Image(systemName: "water.waves")
                        .font(.system(size: 12, weight: .bold))
                    Text("Open Aquarium")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color(.sRGB, red: 0.016, green: 0.129, blue: 0.118, opacity: 1))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    LinearGradient(
                        colors: [
                            Color(.sRGB, red: 0.184, green: 0.761, blue: 0.706, opacity: 1),
                            Color(.sRGB, red: 0.137, green: 0.635, blue: 0.588, opacity: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                achievementsSummary
                Spacer(minLength: 0)
                Button("Settings…", action: onOpenSettings)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
                Text("·").foregroundStyle(.white.opacity(0.2))
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var achievementsSummary: some View {
        let count = store.state.achievements.count
        HStack(spacing: 5) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(count == 0 ? Color.white.opacity(0.35) : .yellow)
                .imageScale(.small)
            Text(count == 1 ? "1 achievement" : "\(count) achievements")
                .foregroundStyle(.white.opacity(0.5))
        }
        .font(.system(size: 10.5))
    }
}

// MARK: - Rows & pills

/// A small header status pill (green "N active", blue "Demo", gray "Idle").
private struct HeaderPill: View {
    let label: String
    let color: Color
    var showDot: Bool = true
    var body: some View {
        HStack(spacing: 4) {
            if showDot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.16), in: Capsule())
    }
}

private struct FishRow: View {
    let fish: FishState

    var body: some View {
        HStack(spacing: 10) {
            FishBadge(fish: fish)

            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 6) {
                    Text(fish.projectTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(fish.provider.displayName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    StatusPill(status: fish.status)
                    Spacer(minLength: 0)
                    Text(String(format: "×%.2f", fish.size))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                ProgressCapsule(fraction: fish.fatigue, fill: Shoal.fatigue(fish.fatigue), height: 3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// The row's left icon: the actual species fish over a faint tinted rounded square.
private struct FishBadge: View {
    let fish: FishState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Shoal.accent(fish.provider).opacity(0.15))
            if let image = FishThumbnail.image(species: fish.species, provider: fish.provider) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            }
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - Display helpers

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
