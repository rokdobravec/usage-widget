import SwiftUI

struct ContributionCellView: View {
    let day: ContributionDay
    let onSelect: (String) -> Void
    let cellSize: CGFloat = 12

    @State private var isHovered = false

    private var opacity: Double {
        if day.isFuture { return 0.35 }
        return day.isInRange ? 1 : 0.4
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(day.intensity.color.opacity(opacity))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                day.isToday
                    ? RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    : nil
            )
            .scaleEffect(isHovered && !day.isFuture ? 1.3 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { if !day.isFuture { onSelect(day.key) } }
            .help(day.tooltipText)
    }
}
