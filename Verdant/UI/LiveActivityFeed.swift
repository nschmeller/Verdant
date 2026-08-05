import SwiftUI

/// A live, newest-first feed of the real steps an analysis is taking right now — which pair is being
/// tested, what's being challenged, what was just kept. Older lines fade so the eye stays on the
/// present moment, and each line slides in cleanly (stable `LogLine.id`). Used by both the
/// user-triggered Deep Analysis and the first-launch catch-up, so a multi-minute wait is never opaque.
struct LiveActivityFeed: View {
    let entries: [AnalysisProgress.LogLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.brand)
                Text("Live activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.brandDeep)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(index == 0 ? Theme.brand : Color.secondary)
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(index == 0 ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .opacity(index == 0 ? 1 : max(0.4, 1 - Double(index) * 0.1))
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
