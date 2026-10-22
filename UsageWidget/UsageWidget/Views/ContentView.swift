import SwiftUI

struct ContentView: View {
    @State var viewModel: StatsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !viewModel.isLoaded {
                Text("Loading…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if let key = viewModel.selectedDay {
                DayDetailView(viewModel: viewModel, dayKey: key)
            } else {
                OverviewView(viewModel: viewModel)
            }
        }
        .frame(width: Layout.width, alignment: .topLeading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .onAppear {
            viewModel.startWatching()
        }
        .onDisappear {
            viewModel.stopWatching()
        }
    }
}

enum Layout {
    static let width: CGFloat = 356
}

// MARK: - Overview

struct OverviewView: View {
    @Bindable var viewModel: StatsViewModel

    var body: some View {
        HStack {
            Text("Claude Code")
                .font(.system(size: 13, weight: .semibold))
            if !viewModel.planLabel.isEmpty {
                Text(viewModel.planLabel)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            RangePicker(selection: $viewModel.range)
        }

        let summary = viewModel.summary
        HStack(spacing: 6) {
            StatTile(title: "Tokens", value: summary.tokens.io.compactFormatted, caption: "input + output")
            StatTile(title: "All tokens", value: summary.tokens.all.compactFormatted, caption: "incl. cache")
            StatTile(title: "Active days", value: summary.activeDays.formatted(), caption: "\(summary.sessions) sessions")
        }

        HStack(alignment: .bottom, spacing: 8) {
            ContributionGraphView(
                weeks: viewModel.weeks,
                monthLabels: viewModel.monthLabels,
                onSelect: { viewModel.selectedDay = $0 }
            )
            Spacer(minLength: 0)
            UsageLimitBarView(
                fiveHourUtil: viewModel.fiveHourUtil,
                sevenDayUtil: viewModel.sevenDayUtil,
                fiveHourReset: viewModel.fiveHourReset,
                sevenDayReset: viewModel.sevenDayReset,
                hasAPIData: viewModel.hasAPIData,
                barHeight: 99
            )
        }

        ModelBreakdownView(models: summary.models)
    }
}

struct RangePicker: View {
    @Binding var selection: UsageRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(UsageRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.title)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(selection == range ? Color(hex: 0xDA7756).opacity(0.85) : .clear)
                        )
                        .foregroundStyle(selection == range ? .white : .secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var caption: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Always reserve the caption line so tiles in a row share one height
            Text(caption ?? " ")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }
}

struct ModelBreakdownView: View {
    let models: [ModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Models")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            if models.isEmpty {
                Text("No usage in this period")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            let total = max(models.reduce(0) { $0 + $1.tokens.all }, 1)
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.displayName)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(model.tokens.all.compactFormatted)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(Color(hex: 0xDA7756))
                                .frame(width: geo.size.width * CGFloat(model.tokens.all) / CGFloat(total))
                        }
                    }
                    .frame(height: 3)
                    Text("In \(model.tokens.input.compactFormatted) · Out \(model.tokens.output.compactFormatted) · Cache read \(model.tokens.cacheRead.compactFormatted) · Cache write \(model.tokens.cacheWrite.compactFormatted)")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help(model.model)
            }
        }
    }
}

// MARK: - Day detail

struct DayDetailView: View {
    let viewModel: StatsViewModel
    let dayKey: String

    var body: some View {
        let day = viewModel.day(dayKey)
        let tokens = day.tokens
        let models = day.tokensByModel
            .map { ModelUsage(model: $0.key, tokens: $0.value) }
            .sorted { $0.tokens.all > $1.tokens.all }

        HStack {
            Button {
                viewModel.selectedDay = nil
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(viewModel.date(for: dayKey).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button { viewModel.stepSelectedDay(by: -1) } label: {
                Image(systemName: "chevron.left.circle").contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous day")
            Button { viewModel.stepSelectedDay(by: 1) } label: {
                Image(systemName: "chevron.right.circle").contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canStepForward)
            .opacity(viewModel.canStepForward ? 1 : 0.3)
            .help("Next day")
        }

        HStack(spacing: 6) {
            StatTile(title: "All tokens", value: tokens.all.compactFormatted, caption: "incl. cache")
            StatTile(title: "Tokens", value: tokens.io.compactFormatted, caption: "input + output")
            StatTile(title: "Sessions", value: day.sessions.count.formatted())
        }
        HStack(spacing: 6) {
            StatTile(title: "Input", value: tokens.input.compactFormatted)
            StatTile(title: "Output", value: tokens.output.compactFormatted)
            StatTile(title: "Cache read", value: tokens.cacheRead.compactFormatted)
            StatTile(title: "Cache write", value: tokens.cacheWrite.compactFormatted)
        }
        HStack(spacing: 6) {
            StatTile(title: "Your messages", value: day.userMessages.formatted())
            StatTile(title: "Claude replies", value: day.replies.formatted())
            StatTile(title: "Peak hour", value: hourRangeText(day.peakHour))
        }

        ModelBreakdownView(models: models)
    }
}
