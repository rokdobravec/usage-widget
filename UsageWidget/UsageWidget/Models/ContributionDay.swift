import SwiftUI

enum IntensityLevel: Int, CaseIterable {
    case empty = 0
    case low = 1
    case medium = 2
    case high = 3
    case veryHigh = 4

    var color: Color {
        switch self {
        case .empty:    return Color(hex: 0x1D1816)
        case .low:      return Color(hex: 0x4A2A1A)
        case .medium:   return Color(hex: 0x8B4A25)
        case .high:     return Color(hex: 0xC15F3C)
        case .veryHigh: return Color(hex: 0xDA7756)
        }
    }

    /// Bucket a day's token total relative to the busiest visible day (sqrt-scaled so
    /// light days still show up next to very heavy ones).
    static func from(tokens: Int, max maxTokens: Int) -> IntensityLevel {
        guard tokens > 0, maxTokens > 0 else { return .empty }
        let ratio = (Double(tokens) / Double(maxTokens)).squareRoot()
        switch ratio {
        case ..<0.25: return .low
        case ..<0.5:  return .medium
        case ..<0.75: return .high
        default:      return .veryHigh
        }
    }
}

struct ContributionDay: Identifiable {
    let date: Date
    let key: String // "yyyy-MM-dd"
    let tokens: Int
    let activity: Int
    let intensity: IntensityLevel
    var isToday: Bool = false
    var isFuture: Bool = false
    var isInRange: Bool = true

    var id: String { key }

    var tooltipText: String {
        let dateStr = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        if isFuture { return dateStr }
        if tokens == 0 && activity == 0 {
            return String(localized: "\(dateStr) — no activity")
        }
        return String(localized: "\(dateStr) — \(tokens.compactFormatted) tokens")
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
