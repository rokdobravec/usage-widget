import Foundation
import SwiftUI

@Observable
final class StatsViewModel {
    var weeks: [[ContributionDay]] = []
    var monthLabels: [(String, Int)] = []
    var range: UsageRange = .all {
        didSet { rebuild() }
    }
    var summary = UsageSummary()
    /// Day key ("yyyy-MM-dd") shown in the detail view, nil for the overview
    var selectedDay: String?
    var planLabel: String = ""
    var isLoaded = false

    static let scaleRange: ClosedRange<Double> = 0.7...1.8
    /// Zoom factor of the whole widget, set with the resize grip
    var scale: Double = UserDefaults.standard.object(forKey: "widgetScale") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(scale, forKey: "widgetScale") }
    }
    /// Locked widgets can't be moved or resized
    var isLocked: Bool = UserDefaults.standard.bool(forKey: "widgetLocked") {
        didSet {
            UserDefaults.standard.set(isLocked, forKey: "widgetLocked")
            onLockChanged?(isLocked)
        }
    }
    @ObservationIgnored var onLockChanged: ((Bool) -> Void)?

    // Real API usage data
    var fiveHourUtil: Double = 0   // 0-100
    var sevenDayUtil: Double = 0   // 0-100
    var fiveHourReset: String = ""
    var sevenDayReset: String = ""
    var hasAPIData = false

    private(set) var days: [String: DayUsage] = [:]
    private var refreshTimer: Timer?
    private var lastAPIFetch: Date = .distantPast
    private var isPaused = false
    private var isScanning = false
    private let weeksToShow = 20
    private let scanner = UsageScanner()
    private let scanQueue = DispatchQueue(label: "UsageWidget.scan", qos: .utility)
    private let liveComputer = LiveStatsComputer()
    private let apiClient = UsageAPIClient()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    init() {
        detectPlan()
        loadCachedAPIData()
    }

    func startWatching() {
        loadData()
        fetchAPIUsage()
        startTimer()
    }

    func stopWatching() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Pause all background activity (display sleep, system sleep, lid close)
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Resume background activity (display wake, system wake)
    func resume() {
        guard isPaused else { return }
        isPaused = false
        startTimer()
        // Refresh immediately on wake
        loadData()
        fetchAPIUsage()
    }

    private func startTimer() {
        // Refresh local stats every 30s; API respects the client's backoff interval.
        // Use .common RunLoop mode so the timer fires during window drags
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.loadData()
            if Date().timeIntervalSince(self.lastAPIFetch) >= self.apiClient.backoffInterval {
                self.fetchAPIUsage()
            }
        }
        timer.tolerance = 10 // Allow macOS to coalesce timer fires for power savings
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func loadData() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let days = self.scanner.scan()
            DispatchQueue.main.async {
                self.days = days
                self.isScanning = false
                self.rebuild()
                self.isLoaded = true
            }
        }
    }

    // MARK: - Day detail

    func day(_ key: String) -> DayUsage {
        days[key] ?? DayUsage()
    }

    func date(for key: String) -> Date {
        dayFormatter.date(from: key) ?? Date()
    }

    /// Move the detail view by `offset` days, never past today
    func stepSelectedDay(by offset: Int) {
        guard let key = selectedDay,
              let next = Calendar.current.date(byAdding: .day, value: offset, to: date(for: key)),
              next <= Date() else { return }
        selectedDay = dayFormatter.string(from: next)
    }

    var canStepForward: Bool {
        guard let key = selectedDay else { return false }
        return key < dayFormatter.string(from: Date())
    }

    // MARK: - Aggregation

    private func rangeStartKey() -> String? {
        guard let count = range.dayCount,
              let start = Calendar.current.date(byAdding: .day, value: -(count - 1), to: Date()) else { return nil }
        return dayFormatter.string(from: start)
    }

    private func rebuild() {
        let startKey = rangeStartKey()
        let inRange = days.filter { startKey == nil || $0.key >= startKey! }
        summary = UsageSummary(days: Array(inRange.values))
        buildGrid(rangeStartKey: startKey)
    }

    private func buildGrid(rangeStartKey: String?) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let todayKey = dayFormatter.string(from: today)

        // Weeks run Sunday → Saturday, GitHub style; the last column is the current week.
        let todayWeekday = calendar.component(.weekday, from: today)
        let endOfCurrentWeek = calendar.date(byAdding: .day, value: 7 - todayWeekday, to: today)!
        let startDate = calendar.date(byAdding: .day, value: -(weeksToShow * 7 - 1), to: endOfCurrentWeek)!

        let visibleKeys = (0..<(weeksToShow * 7)).map {
            dayFormatter.string(from: calendar.date(byAdding: .day, value: $0, to: startDate)!)
        }
        let maxTokens = visibleKeys.compactMap { days[$0]?.tokens.all }.max() ?? 0

        var newWeeks: [[ContributionDay]] = []
        var newMonthLabels: [(String, Int)] = []
        var lastMonth = -1

        for weekIndex in 0..<weeksToShow {
            var week: [ContributionDay] = []
            for dayIndex in 0..<7 {
                let date = calendar.date(byAdding: .day, value: weekIndex * 7 + dayIndex, to: startDate)!
                let key = visibleKeys[weekIndex * 7 + dayIndex]

                let month = calendar.component(.month, from: date)
                if dayIndex == 0 && month != lastMonth {
                    newMonthLabels.append((date.formatted(.dateTime.month(.abbreviated)), weekIndex))
                    lastMonth = month
                }

                let usage = days[key]
                let tokens = usage?.tokens.all ?? 0
                var day = ContributionDay(
                    date: date,
                    key: key,
                    tokens: tokens,
                    activity: usage?.activity ?? 0,
                    intensity: IntensityLevel.from(tokens: tokens, max: maxTokens)
                )
                day.isToday = key == todayKey
                day.isFuture = date > today
                day.isInRange = rangeStartKey == nil || key >= rangeStartKey!
                week.append(day)
            }
            newWeeks.append(week)
        }

        weeks = newWeeks
        monthLabels = newMonthLabels
    }

    // MARK: - Rate limits (Anthropic API)

    func fetchAPIUsage() {
        lastAPIFetch = Date()
        Task {
            guard let usage = await apiClient.fetchUsage() else {
                // Retry once after 5s if we've never loaded API data
                if !hasAPIData {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let retry = await apiClient.fetchUsage() else { return }
                    await applyUsage(retry)
                }
                return
            }

            await applyUsage(usage)
        }
    }

    @MainActor
    private func applyUsage(_ usage: UsageData) {
        if let fh = usage.fiveHour {
            fiveHourUtil = fh.utilization
            fiveHourReset = formatReset(fh.resetsAt)
        }
        if let sd = usage.sevenDay {
            sevenDayUtil = sd.utilization
            sevenDayReset = formatReset(sd.resetsAt)
        }
        hasAPIData = true
        saveCachedAPIData()
    }

    // MARK: - API Data Caching (survives app restarts)

    private func saveCachedAPIData() {
        let defaults = UserDefaults.standard
        defaults.set(fiveHourUtil, forKey: "cachedFiveHourUtil")
        defaults.set(sevenDayUtil, forKey: "cachedSevenDayUtil")
        defaults.set(fiveHourReset, forKey: "cachedFiveHourReset")
        defaults.set(sevenDayReset, forKey: "cachedSevenDayReset")
        defaults.set(Date().timeIntervalSince1970, forKey: "cachedAPIDataTimestamp")
    }

    private func loadCachedAPIData() {
        let defaults = UserDefaults.standard
        let timestamp = defaults.double(forKey: "cachedAPIDataTimestamp")
        guard timestamp > 0 else { return }

        // Use cached data if less than 1 hour old
        let age = Date().timeIntervalSince1970 - timestamp
        guard age < 3600 else { return }

        fiveHourUtil = defaults.double(forKey: "cachedFiveHourUtil")
        sevenDayUtil = defaults.double(forKey: "cachedSevenDayUtil")
        fiveHourReset = defaults.string(forKey: "cachedFiveHourReset") ?? ""
        sevenDayReset = defaults.string(forKey: "cachedSevenDayReset") ?? ""
        hasAPIData = true
    }

    private func detectPlan() {
        let tier = liveComputer.readRateLimitTier() ?? ""
        if tier.contains("max_20x") { planLabel = "Max 20x" }
        else if tier.contains("max_5x") { planLabel = "Max 5x" }
        else if tier.contains("max") { planLabel = "Max" }
        else if tier.contains("pro") { planLabel = "Pro" }
        else if !tier.isEmpty { planLabel = "Free" }
        else { planLabel = "" } // unknown: credentials not readable
    }

    private func formatReset(_ date: Date?) -> String {
        guard let date else { return "" }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return String(localized: "now") }

        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
