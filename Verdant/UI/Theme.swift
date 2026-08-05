import SwiftUI

/// Verdant's design system: a lush, botanical green palette — fresh leaf, deep forest, and new
/// growth. Kept in one place so the look stays cohesive and easy to retune.
enum Theme {
    /// Primary leaf green — accents, the app tint, and emphasis.
    static let brand = Color(red: 0.17, green: 0.62, blue: 0.38)
    /// Deep forest green for headings and high-contrast text on light tints.
    static let brandDeep = Color(red: 0.05, green: 0.35, blue: 0.21)
    /// Fresh new-growth green for bright highlights.
    static let sprout = Color(red: 0.52, green: 0.80, blue: 0.42)
    /// Soft mint wash for card and chip fills.
    static let brandSoft = Color(red: 0.17, green: 0.62, blue: 0.38).opacity(0.13)

    /// A lush canopy gradient: fresh leaf at the top, forest floor at the base.
    static let gradient = LinearGradient(
        colors: [Color(red: 0.27, green: 0.72, blue: 0.44), Color(red: 0.05, green: 0.39, blue: 0.25)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cornerRadius: CGFloat = 18
}

extension Direction {
    var tint: Color {
        switch self {
        case .up: Theme.brand
        case .down: Color(red: 0.20, green: 0.52, blue: 0.78)
        case .flat: .secondary
        }
    }
}

/// A soft, rounded card surface used throughout the app.
struct Card: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(tint ?? Color(uiColor: .secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            )
    }
}

extension View {
    func card(tint: Color? = nil) -> some View {
        modifier(Card(tint: tint))
    }
}

/// A compact labelled stat chip (e.g. "3 insights").
struct StatChip: View {
    let value: String
    let label: String
    var emphasized = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(emphasized ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brandSoft)
        )
    }
}
