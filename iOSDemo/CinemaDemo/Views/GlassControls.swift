import SwiftUI

enum CinemaTheme {
    static let accent = Color(red: 1, green: 0.784, blue: 0)
    static let actionGold = Color(red: 244 / 255, green: 200 / 255, blue: 90 / 255)
    static let availableSeat = Color(red: 170 / 255, green: 171 / 255, blue: 183 / 255)
    static let background = Color(red: 0.106, green: 0.110, blue: 0.129)
    static let panel = Color(red: 0.145, green: 0.149, blue: 0.176)
}

struct GlassPanel<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 30).fill(CinemaTheme.panel)
                } else {
                    RoundedRectangle(cornerRadius: 30).fill(CinemaTheme.panel.opacity(0.28))
                }
            }
            .glassEffect(reduceTransparency ? .identity : .regular,
                         in: .rect(cornerRadius: 30))
            .overlay {
                RoundedRectangle(cornerRadius: 30)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

struct PrimaryAction: View {
    let title: String
    var symbol: String? = nil
    var isLoading = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading { ProgressView().tint(.black) }
                if let symbol, !isLoading { Image(systemName: symbol) }
                Text(title)
            }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .controlSize(.large)
        .foregroundStyle(Color.black.opacity(0.9))
        .tint(CinemaTheme.actionGold)
        .disabled(isLoading)
    }
}

struct SeatLegend: View {
    var body: some View {
        HStack(spacing: 24) {
            item("可选", color: CinemaTheme.availableSeat)
            item("已售", color: Color(red: 0.29, green: 0.30, blue: 0.33))
            item("已选", color: CinemaTheme.accent)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
    private func item(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 9, height: 9)
            Text(title)
        }
    }
}

struct SecondaryAction: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 27)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .tint(.white)
    }
}
