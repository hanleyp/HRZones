//
//  ContentView.swift
//  HRZonesMac
//
//  Dashboard: import a Health export, week/month toggle, Zone 2 progress
//  toward the 80% target, per-day stacked bars, zone distribution.
//

import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: HealthExportStore
    @EnvironmentObject private var zoneStore: ZoneStore

    @State private var range: AnalysisRange = .week
    @State private var showingZoneEditor = false
    @State private var showingImporter = false

    private let zone2Target = 0.80

    /// When false (default), Zone 1 is treated as neutral warmup/cooldown
    /// time and excluded from the target calculation: the ring shows
    /// Zone 2 / (Zones 2–5). When true, the strict Zone 2 / all-time
    /// metric is used.
    @AppStorage("hrzones.includeZone1") private var includeZone1 = false

    /// Optimal weekly Zone 2 volume, editable in the zone editor.
    @AppStorage("hrzones.weeklyGoalMin") private var weeklyGoalMin = 150
    @AppStorage("hrzones.weeklyGoalMax") private var weeklyGoalMax = 180

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                switch store.state {
                case .empty:
                    emptyState
                case .loading(let status):
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Choose a different file…") { showingImporter = true }
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                case .ready:
                    if store.summary.totalSeconds == 0 {
                        noWorkoutsState
                    } else {
                        zone2Card
                        weeklyGoalCard
                        dailyChart
                        distributionCard
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Training Zones")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Range", selection: $range) {
                    ForEach(AnalysisRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(store.state != .ready)

                Button {
                    showingImporter = true
                } label: {
                    Label("Open Export…", systemImage: "square.and.arrow.down")
                }
                Button {
                    showingZoneEditor = true
                } label: {
                    Label("Edit Zones", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showingZoneEditor) {
            ZoneEditorView()
                .environmentObject(zoneStore)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.zip, .xml, .folder, .json, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.load(url: url)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in store.load(url: url) }
                }
            }
            return true
        }
        .task {
            store.loadLastSourceIfAvailable()
        }
        .onChange(of: store.state) { _, newState in
            if newState == .ready {
                if let age = store.ageFromExport {
                    zoneStore.applyEstimatedMaxHR(fromAge: age)
                }
                store.analyze(range: range, zones: zoneStore.zones)
            }
        }
        .onChange(of: range) { _, newRange in
            store.analyze(range: newRange, zones: zoneStore.zones)
        }
        .onChange(of: zoneStore.zones) { _, newZones in
            store.analyze(range: range, zones: newZones)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if let name = store.sourceFileName, store.state == .ready {
                    Text(name).font(.headline)
                    if let exportDate = store.exportDate {
                        Text("Exported \(exportDate.formatted(date: .abbreviated, time: .shortened)) · \(store.workoutCount) workouts in range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: Zone 2 target card

    /// Seconds counted in the denominator under the current setting.
    private var targetDenominatorSeconds: TimeInterval {
        let total = store.summary.totalSeconds
        guard !includeZone1 else { return total }
        return total - (store.summary.secondsPerZone[1] ?? 0)
    }

    private var zone2Fraction: Double {
        let denom = targetDenominatorSeconds
        guard denom > 0 else { return 0 }
        return (store.summary.secondsPerZone[2] ?? 0) / denom
    }

    private var zone2Card: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Zone 2 Target").font(.headline)
                Spacer()
            }
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: min(zone2Fraction / zone2Target, 1.0))
                    .stroke(
                        zone2Fraction >= zone2Target ? Color.green : Color.orange,
                        style: StrokeStyle(lineWidth: 16, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(zone2Fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("of \(Int(zone2Target * 100))% goal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 170, height: 170)
            .animation(.easeOut, value: zone2Fraction)

            Text(zone2Message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Toggle("Count Zone 1 time toward the total", isOn: $includeZone1)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Off: Zone 1 is neutral warmup/cooldown time and the target is Zone 2 ÷ Zones 2–5. On: strict Zone 2 ÷ all workout time.")
        }
        .padding()
        .background(cardBackground)
    }

    private var metricDescription: String {
        includeZone1 ? "training time" : "Zone 2–5 time"
    }

    private var zone2Message: String {
        let pct = Int((zone2Fraction * 100).rounded())
        if zone2Fraction >= zone2Target {
            return "On target — \(pct)% of your \(metricDescription) was in Zone 2."
        }
        let neededSeconds = neededZone2Seconds()
        let minutes = Int((neededSeconds / 60).rounded(.up))
        return "\(pct)% of \(metricDescription) in Zone 2. Roughly \(minutes) more Zone 2 minutes would bring this period to 80%."
    }

    private func neededZone2Seconds() -> TimeInterval {
        let denom = targetDenominatorSeconds
        let z2 = store.summary.secondsPerZone[2] ?? 0
        let t = zone2Target
        guard t < 1 else { return 0 }
        // Solve (z2 + x) / (denom + x) = t for x: added Zone 2 minutes
        // enter both numerator and denominator.
        return max((t * denom - z2) / (1 - t), 0)
    }


    // MARK: Weekly Zone 2 goal

    /// Week view: Zone 2 minutes over the trailing 7 days.
    /// Month view: AVERAGE Zone 2 minutes per week across the whole month,
    /// so the card reflects your typical week rather than just the latest one.
    private var weeklyZone2Minutes: Double {
        switch range {
        case .week:
            let last7 = store.dailyBreakdowns.suffix(7)
            let seconds = last7.reduce(0.0) { $0 + ($1.secondsPerZone[2] ?? 0) }
            return seconds / 60
        case .month:
            let totalSeconds = store.summary.secondsPerZone[2] ?? 0
            let weeks = Double(range.days) / 7.0
            return (totalSeconds / 60) / weeks
        }
    }

    private var weeklyGoalCard: some View {
        let minutes = weeklyZone2Minutes
        let lower = Double(weeklyGoalMin)
        let upper = Double(max(weeklyGoalMax, weeklyGoalMin))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(range == .week ? "Weekly Zone 2 Volume" : "Avg Weekly Zone 2 Volume").font(.headline)
                Spacer()
                Text("Goal \(weeklyGoalMin)–\(Int(upper)) min/wk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let scaleMax = max(upper * 1.2, minutes, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    // Optimal band
                    Rectangle()
                        .fill(Color.green.opacity(0.18))
                        .frame(width: geo.size.width * (upper - lower) / scaleMax)
                        .offset(x: geo.size.width * lower / scaleMax)
                    // Progress
                    Capsule()
                        .fill(minutes >= lower ? Color.green : Color.orange)
                        .frame(width: max(geo.size.width * min(minutes / scaleMax, 1), minutes > 0 ? 4 : 0))
                    // Goal boundary ticks
                    ForEach([lower, upper], id: \.self) { mark in
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * mark / scaleMax)
                    }
                }
            }
            .frame(height: 14)
            .clipShape(Capsule())

            Text(weeklyGoalMessage(minutes: minutes, lower: lower, upper: upper))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(cardBackground)
    }

    private func weeklyGoalMessage(minutes: Double, lower: Double, upper: Double) -> String {
        let m = Int(minutes.rounded())
        let scope = range == .week
            ? "\(m) Zone 2 minutes in the last 7 days"
            : "Averaging \(m) Zone 2 minutes per week over the past month"
        if minutes < lower {
            let remaining = Int((lower - minutes).rounded(.up))
            return "\(scope) — \(remaining) more per week to reach the optimal range."
        } else if minutes <= upper {
            return "\(scope) — inside your optimal range. Nice."
        } else {
            return "\(scope) — above the optimal range. Extra easy volume is generally fine."
        }
    }

    // MARK: Daily chart

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Time in Zones").font(.headline)
            Chart {
                ForEach(store.dailyBreakdowns) { day in
                    ForEach(zoneStore.zones) { zone in
                        if let secs = day.secondsPerZone[zone.id], secs > 0 {
                            BarMark(
                                x: .value("Day", day.day, unit: .day),
                                y: .value("Minutes", secs / 60)
                            )
                            .foregroundStyle(by: .value("Zone", zone.label))
                        }
                    }
                }
            }
            .chartForegroundStyleScale(zoneColorScale)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxisLabel("min")
            .frame(height: 260)
        }
        .padding()
        .background(cardBackground)
    }

    private var zoneColorScale: KeyValuePairs<String, Color> {
        [
            "Zone 1": zoneStore.zones[0].color,
            "Zone 2": zoneStore.zones[1].color,
            "Zone 3": zoneStore.zones[2].color,
            "Zone 4": zoneStore.zones[3].color,
            "Zone 5": zoneStore.zones[4].color,
        ]
    }

    // MARK: Distribution

    private var distributionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Zone Distribution").font(.headline)
                Spacer()
                if !includeZone1 {
                    Text("Zone 1 excluded from target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(zoneStore.zones) { zone in
                let seconds = store.summary.secondsPerZone[zone.id] ?? 0
                let excluded = (zone.id == 1 && !includeZone1)
                let denom = targetDenominatorSeconds
                let fraction = (excluded || denom <= 0) ? 0 : seconds / denom
                HStack {
                    Circle().fill(zone.color).frame(width: 10, height: 10)
                    Text(zone.label)
                        .font(.subheadline)
                        .frame(width: 60, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.gray.opacity(0.2))
                            Capsule()
                                .fill(zone.color)
                                .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
                        }
                    }
                    .frame(height: 10)
                    Text(excluded ? "—" : "\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                    Text(formatDuration(seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 55, alignment: .trailing)
                }
                .opacity(excluded ? 0.45 : 1)
            }
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: Empty states

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Open a Health export",
                systemImage: "heart.text.square",
                description: Text("""
                Fastest: use the Health Auto Export app on iPhone to export \
                Heart Rate (JSON or CSV) to an iCloud Drive folder, then open \
                that file or folder here. Or use the full export: Health app \
                → profile picture → Export All Health Data → AirDrop \
                export.zip. Open or drag any of them onto this window — the \
                app remembers your last source and reloads it at launch.
                """)
            )
            Button("Open export…") { showingImporter = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var noWorkoutsState: some View {
        ContentUnavailableView(
            "No workouts in this period",
            systemImage: "figure.run",
            description: Text("The export parsed successfully, but no workouts with heart-rate data were found in the selected \(range.rawValue.lowercased()). Try the Month view, or make a fresh export after your next workout.")
        )
        .frame(minHeight: 300)
    }

    // MARK: Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            return String(format: "%dh %02dm", minutes / 60, minutes % 60)
        }
        return "\(minutes)m"
    }
}
