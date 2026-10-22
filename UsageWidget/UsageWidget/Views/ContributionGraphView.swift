import SwiftUI

struct ContributionGraphView: View {
    let weeks: [[ContributionDay]]
    let monthLabels: [(String, Int)]
    let onSelect: (String) -> Void

    private let cellSize: CGFloat = 12
    private let spacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                ForEach(monthLabels, id: \.1) { label, weekIndex in
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(weekIndex) * (cellSize + spacing))
                }
            }
            .frame(width: CGFloat(weeks.count) * (cellSize + spacing), height: 11, alignment: .topLeading)

            HStack(spacing: spacing) {
                ForEach(weeks.indices, id: \.self) { weekIndex in
                    VStack(spacing: spacing) {
                        ForEach(weeks[weekIndex]) { day in
                            ContributionCellView(day: day, onSelect: onSelect)
                        }
                    }
                }
            }
        }
    }
}
