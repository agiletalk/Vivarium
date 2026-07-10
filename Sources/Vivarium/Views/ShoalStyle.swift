import SwiftUI
import VivariumCore

/// Shared SwiftUI styling for the "Shoal" design surfaces (popover, aquarium HUD, fish detail).
///
/// Colors bridge the exact `TextureFactory` palette so SwiftUI chrome and the SpriteKit scene read
/// identical hex values; the SpriteKit side keeps using the `NSColor` accessors directly.
enum Shoal {
    static func accent(_ provider: AgentProvider) -> Color { Color(nsColor: TextureFactory.accent(for: provider)) }
    static func status(_ status: AgentStatus) -> Color { Color(nsColor: TextureFactory.statusColor(for: status)) }
    static func memory(_ domain: MemoryDomain) -> Color { Color(nsColor: TextureFactory.memoryColor(for: domain)) }

    /// Green "active" accent used by the popover's live-agent pill and count.
    static let active = Color(.sRGB, red: 0.188, green: 0.820, blue: 0.345, opacity: 1) // #30D158
    /// Reef/link teal accent (#40C8E0) — stage names, progress ring, "View transcript" link.
    static let reefAccent = Color(.sRGB, red: 0.251, green: 0.784, blue: 0.878, opacity: 1)
    /// Teal reef-progress gradient (#29BDB0 → reefAccent).
    static let reefGradient = LinearGradient(
        colors: [Color(.sRGB, red: 0.161, green: 0.741, blue: 0.690, opacity: 1), reefAccent],
        startPoint: .leading, endPoint: .trailing
    )

    /// Fatigue bar/label color ramp (matches the design: green < 40%, yellow < 75%, amber above).
    static func fatigue(_ value: Double) -> Color {
        switch value {
        case ..<0.4: Color(.sRGB, red: 0.188, green: 0.820, blue: 0.345, opacity: 1) // #30D158
        case ..<0.75: Color(.sRGB, red: 1.0, green: 0.839, blue: 0.039, opacity: 1)  // #FFD60A
        default: Color(.sRGB, red: 1.0, green: 0.624, blue: 0.039, opacity: 1)       // #FF9F0A
        }
    }
}

extension AmbientPhase {
    /// The next phase when the aquarium HUD's time-of-day button is tapped.
    var cycled: AmbientPhase {
        switch self {
        case .dawn: .day
        case .day: .evening
        case .evening: .night
        case .night: .dawn
        }
    }

    var emoji: String {
        switch self {
        case .dawn: "🌅"
        case .day: "☀️"
        case .evening: "🌇"
        case .night: "🌙"
        }
    }

    /// Korean lighting label shown in the popover header (e.g. "낮 조명").
    var lightingLabel: String {
        switch self {
        case .dawn: "새벽 조명"
        case .day: "낮 조명"
        case .evening: "저녁 조명"
        case .night: "밤 조명"
        }
    }
}

/// A horizontal progress/meter bar: a translucent track with a fraction-filled capsule.
/// Shared by the popover reef bar, the fatigue bars, and the detail-panel meter.
struct ProgressCapsule<Fill: ShapeStyle>: View {
    let fraction: Double
    let fill: Fill
    var height: CGFloat = 4
    var track: Color = .white.opacity(0.14)

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(2, geo.size.width * clamped))
            }
        }
        .frame(height: height)
    }
}

/// A status chip: a colored dot plus the humanized status label, tinted by status color.
struct StatusPill: View {
    let status: AgentStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Shoal.status(status))
                .frame(width: 5, height: 5)
            Text(status.humanized)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Shoal.status(status))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 1.5)
        .background(Shoal.status(status).opacity(0.14), in: Capsule())
    }
}
