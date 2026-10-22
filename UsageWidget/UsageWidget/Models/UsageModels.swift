import Foundation

struct TokenCounts: Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0

    /// Input + output, excluding cache
    var io: Int { input + output }
    /// Input + output + cache read + cache write
    var all: Int { input + output + cacheRead + cacheWrite }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
    }
}

struct DayUsage {
    var tokensByModel: [String: TokenCounts] = [:]
    var userMessages = 0
    var replies = 0
    var sessions: Set<String> = []
    var hourlyActivity = [Int](repeating: 0, count: 24)

    var tokens: TokenCounts {
        tokensByModel.values.reduce(into: TokenCounts()) { $0 += $1 }
    }
    var activity: Int { userMessages + replies }
    var peakHour: Int? {
        guard let maxValue = hourlyActivity.max(), maxValue > 0 else { return nil }
        return hourlyActivity.firstIndex(of: maxValue)
    }
}

enum UsageRange: String, CaseIterable, Identifiable {
    case all, days30, days7

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .all: return "All"
        case .days30: return "30d"
        case .days7: return "7d"
        }
    }

    /// Number of days including today, or nil for all time
    var dayCount: Int? {
        switch self {
        case .all: return nil
        case .days30: return 30
        case .days7: return 7
        }
    }
}

struct ModelUsage: Identifiable {
    let model: String
    let tokens: TokenCounts
    var id: String { model }

    /// "claude-opus-5-5" → "Opus 5.5"
    var displayName: String { Self.displayName(for: model) }

    static func displayName(for model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Drop trailing date stamps like 20250101
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}

struct UsageSummary {
    var tokens = TokenCounts()
    var activeDays = 0
    var sessions = 0
    var userMessages = 0
    var replies = 0
    var models: [ModelUsage] = []
    var peakHour: Int?

    init() {}

    init(days: [DayUsage]) {
        var byModel: [String: TokenCounts] = [:]
        var sessionIds = Set<String>()
        var hours = [Int](repeating: 0, count: 24)
        for day in days {
            for (model, counts) in day.tokensByModel { byModel[model, default: TokenCounts()] += counts }
            sessionIds.formUnion(day.sessions)
            userMessages += day.userMessages
            replies += day.replies
            if day.activity > 0 || day.tokens.all > 0 { activeDays += 1 }
            for h in 0..<24 { hours[h] += day.hourlyActivity[h] }
        }
        tokens = byModel.values.reduce(into: TokenCounts()) { $0 += $1 }
        sessions = sessionIds.count
        models = byModel.map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.all > $1.tokens.all }
        if let maxValue = hours.max(), maxValue > 0 { peakHour = hours.firstIndex(of: maxValue) }
    }
}

extension Int {
    /// 1234 → "1.2K", 233150628 → "233.2M"
    var compactFormatted: String {
        formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

func hourRangeText(_ hour: Int?) -> String {
    guard let hour else { return "—" }
    return String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
}
