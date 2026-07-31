//
//  ZoneEditorView.swift
//  HRZonesMac
//
//  Manual editor for heart-rate zone boundaries. Needed because Apple's
//  Health export does not include the zone ranges configured on the
//  Watch — copy them from Watch app → Workout → Heart Rate Zones for an
//  exact match, or use the max-HR defaults.
//

import SwiftUI

struct ZoneEditorView: View {
    @EnvironmentObject private var zoneStore: ZoneStore
    @Environment(\.dismiss) private var dismiss

    @State private var showResetConfirm = false

    @AppStorage("hrzones.weeklyGoalMin") private var weeklyGoalMin = 150
    @AppStorage("hrzones.weeklyGoalMax") private var weeklyGoalMax = 180

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Stepper(value: $zoneStore.maxHR, in: 120...220) {
                        HStack {
                            Text("Max heart rate")
                            Spacer()
                            Text("\(zoneStore.maxHR) bpm")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Button("Recalculate zones from max HR") {
                        zoneStore.recalculateFromMaxHR()
                    }
                    Text("Defaults to 220 − age (age read from the export's profile). Recalculating overwrites manual edits using the standard 50/60/70/80/90% bands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Max HR")
                }

                Section {
                    Stepper(value: Binding(
                        get: { weeklyGoalMin },
                        set: { weeklyGoalMin = $0; if weeklyGoalMax < $0 { weeklyGoalMax = $0 } }
                    ), in: 30...600, step: 5) {
                        HStack {
                            Text("Weekly Zone 2 goal (min)")
                            Spacer()
                            Text("\(weeklyGoalMin) min")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: Binding(
                        get: { weeklyGoalMax },
                        set: { weeklyGoalMax = $0; if weeklyGoalMin > $0 { weeklyGoalMin = $0 } }
                    ), in: 30...600, step: 5) {
                        HStack {
                            Text("Weekly Zone 2 goal (max)")
                            Spacer()
                            Text("\(weeklyGoalMax) min")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Text("Research commonly cites 150–180 minutes of Zone 2 cardio per week as an optimal target for aerobic health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Weekly Zone 2 goal")
                }

                Section {
                    ForEach($zoneStore.zones) { $zone in
                        ZoneRow(zone: $zone) {
                            zoneStore.userEdited = true
                        }
                    }
                    Text("Health exports don't include your Watch zone settings — copy them here from Watch app → Workout → Heart Rate Zones for an exact match.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Zone ranges (bpm)")
                }

                if let issue = validationIssue {
                    Section {
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 620)
        .confirmationDialog("Reset all zones to defaults calculated from max HR?",
                            isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { zoneStore.resetToDefaults() }
        }
    }

    private var validationIssue: String? {
        let sorted = zoneStore.zones.sorted { $0.id < $1.id }
        for i in 0..<(sorted.count - 1) {
            let current = sorted[i], next = sorted[i + 1]
            if current.upperBPM >= next.lowerBPM {
                return "\(current.label) and \(next.label) overlap — samples in the overlap count toward the lower zone."
            }
            if next.lowerBPM - current.upperBPM > 1 {
                return "Gap between \(current.label) and \(next.label) — heart rates in the gap won't be counted."
            }
        }
        for zone in sorted where zone.lowerBPM > zone.upperBPM {
            return "\(zone.label) has a lower bound above its upper bound."
        }
        return nil
    }
}

// MARK: - Row

private struct ZoneRow: View {
    @Binding var zone: HRZone
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(zone.color).frame(width: 12, height: 12)
                Text(zone.label).font(.headline)
                Text(zone.descriptor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(zone.lowerBPM)–\(zone.upperBPM)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                labeledField("Low", value: $zone.lowerBPM)
                labeledField("High", value: $zone.upperBPM)
            }
        }
        .padding(.vertical, 2)
    }

    private func labeledField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(max($0, 30), 230); onEdit() }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .multilineTextAlignment(.trailing)
            Stepper("", value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = $0; onEdit() }
            ), in: 30...230)
            .labelsHidden()
        }
    }
}
