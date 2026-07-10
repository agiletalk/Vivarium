import SwiftUI
import VivariumCore

/// The fish detail panel that slides in at the right of the aquarium window when a fish is
/// selected. Purely presentational — every field comes from the selected `FishState`.
struct FishDetailPanel: View {
    let fish: FishState
    var onClose: () -> Void = {}

    private var accent: Color { Shoal.accent(fish.provider) }

    var body: some View {
        VStack(spacing: 0) {
            banner
            details
        }
        .frame(width: 300)
        .background(
            Color(.sRGB, red: 0.094, green: 0.125, blue: 0.188, opacity: 0.92),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 28, y: 20)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Banner + portrait

    private var banner: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [accent.opacity(0.22), accent.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            if let portrait = FishThumbnail.image(species: fish.species, provider: fish.provider) {
                Image(nsImage: portrait)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 150, height: 86)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(height: 96)
        .clipped()
    }

    // MARK: - Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            chips
            statGrid
            fatigue
            expertise
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(fish.projectTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(fish.provider.displayName) · \(fish.species.displayName)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(accent.opacity(0.14), in: Capsule())
                    .lineLimit(1)
            }
            HStack(spacing: 5) {
                Circle().fill(Shoal.status(fish.status)).frame(width: 5, height: 5)
                Text(fish.status.humanized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Shoal.status(fish.status))
            }
        }
    }

    @ViewBuilder
    private var chips: some View {
        let items = [fish.model, fish.gitBranch.map { "⎇ \($0)" }].compactMap { $0 }
        if !items.isEmpty {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { text in
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .lineLimit(1)
                }
            }
        }
    }

    private var statGrid: some View {
        HStack(spacing: 6) {
            stat("\(fish.tasksCompleted)", "tasks done")
            stat("\(fish.tasksFailed)", "missed")
            stat(String(format: "×%.2f", fish.size), "growth")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var fatigue: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Fatigue")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                Text("\(Int((fish.fatigue * 100).rounded()))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Shoal.fatigue(fish.fatigue))
            }
            ProgressCapsule(fraction: fish.fatigue, fill: Shoal.fatigue(fish.fatigue))
        }
    }

    private var expertise: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Expertise — Memory Fish")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            if fish.memory.isEmpty {
                Text("No expertise yet — complete tasks to grow stripes.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(fish.memory.sorted { $0.level > $1.level }) { trait in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Shoal.memory(trait.domain))
                            .frame(width: 34, height: 8)
                        Text(trait.domain.rawValue.capitalized)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 0)
                        Text(dots(for: trait.level))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }

    private func dots(for level: Int) -> String {
        let filled = min(max(level, 0), 5)
        return String(repeating: "●", count: filled) + String(repeating: "○", count: 5 - filled)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(fish.isResident ? "\(fish.sessionCount) sessions · resident" : "\(fish.sessionCount) sessions")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 0)
            Text("View transcript →")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Shoal.reefAccent)
        }
        .padding(.top, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}
