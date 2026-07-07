import SwiftUI

/// Renders `store.banner` as a card that slides in from the top of the aquarium window.
/// The store owns the 4-second dismiss timer; this view only reflects the current value.
struct BannerOverlay: View {
    let store: VivariumStore

    var body: some View {
        VStack {
            if let banner = store.banner {
                card(for: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: store.banner)
    }

    private func card(for banner: BannerModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: banner.systemImage)
                .font(.title2)
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.yellow)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.headline)
                Text(banner.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
    }
}
