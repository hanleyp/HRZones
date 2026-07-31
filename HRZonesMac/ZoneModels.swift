//
//  ZoneModels.swift
//  HRZonesMac
//
//  Heart-rate zone definitions with defaults derived from max HR, plus
//  persistence for manual edits. The Health export does not include the
//  zone boundaries configured on your Watch, so zones are estimated from
//  max HR and fully user-editable.
//

import Foundation
import Combine
import SwiftUI

// MARK: - Zone

struct HRZone: Identifiable, Codable, Equatable {
    var id: Int              // 1...5
    var name: String
    var lowerBPM: Int        // inclusive
    var upperBPM: Int        // inclusive

    var label: String { "Zone \(id)" }

    func contains(_ bpm: Double) -> Bool {
        bpm >= Double(lowerBPM) && bpm <= Double(upperBPM)
    }
}

extension HRZone {
    /// Colors roughly matching Apple's Workout app zone palette.
    var color: Color {
        switch id {
        case 1: return Color(red: 0.55, green: 0.78, blue: 0.98) // light blue
        case 2: return Color(red: 0.30, green: 0.85, blue: 0.55) // green
        case 3: return Color(red: 0.99, green: 0.80, blue: 0.25) // yellow
        case 4: return Color(red: 0.99, green: 0.55, blue: 0.20) // orange
        case 5: return Color(red: 0.95, green: 0.26, blue: 0.30) // red
        default: return .gray
        }
    }

    var descriptor: String {
        switch id {
        case 1: return "Recovery"
        case 2: return "Aerobic base"
        case 3: return "Tempo"
        case 4: return "Threshold"
        case 5: return "VO₂ max"
        default: return ""
        }
    }
}

// MARK: - Zone configuration store

@MainActor
final class ZoneStore: ObservableObject {
    @Published var zones: [HRZone] {
        didSet { save() }
    }
    @Published var maxHR: Int {
        didSet { UserDefaults.standard.set(maxHR, forKey: Self.maxHRKey) }
    }
    @Published var userEdited: Bool {
        didSet { UserDefaults.standard.set(userEdited, forKey: Self.editedKey) }
    }

    static let zonesKey = "hrzones.zones"
    static let maxHRKey = "hrzones.maxHR"
    static let editedKey = "hrzones.userEdited"

    init() {
        let storedMax = UserDefaults.standard.integer(forKey: Self.maxHRKey)
        let max = storedMax > 0 ? storedMax : 180
        self.maxHR = max
        self.userEdited = UserDefaults.standard.bool(forKey: Self.editedKey)

        if let data = UserDefaults.standard.data(forKey: Self.zonesKey),
           let decoded = try? JSONDecoder().decode([HRZone].self, from: data) {
            self.zones = decoded
        } else {
            self.zones = ZoneStore.defaultZones(maxHR: max)
        }
    }

    /// Standard 5-zone model as percentages of max HR — the same scheme
    /// Apple uses when auto-calculating Watch workout zones.
    static func defaultZones(maxHR: Int) -> [HRZone] {
        let m = Double(maxHR)
        func bpm(_ pct: Double) -> Int { Int((pct * m).rounded()) }
        return [
            HRZone(id: 1, name: "Zone 1", lowerBPM: bpm(0.50), upperBPM: bpm(0.60) - 1),
            HRZone(id: 2, name: "Zone 2", lowerBPM: bpm(0.60), upperBPM: bpm(0.70) - 1),
            HRZone(id: 3, name: "Zone 3", lowerBPM: bpm(0.70), upperBPM: bpm(0.80) - 1),
            HRZone(id: 4, name: "Zone 4", lowerBPM: bpm(0.80), upperBPM: bpm(0.90) - 1),
            HRZone(id: 5, name: "Zone 5", lowerBPM: bpm(0.90), upperBPM: 220),
        ]
    }

    /// Seed max HR from the date of birth found in the Health export
    /// (220 − age), unless the user has already customized things.
    func applyEstimatedMaxHR(fromAge age: Int) {
        guard !userEdited, UserDefaults.standard.integer(forKey: Self.maxHRKey) == 0 else { return }
        maxHR = 220 - age
        zones = ZoneStore.defaultZones(maxHR: maxHR)
    }

    func recalculateFromMaxHR() {
        zones = ZoneStore.defaultZones(maxHR: maxHR)
        userEdited = false
    }

    func resetToDefaults() {
        recalculateFromMaxHR()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(zones) {
            UserDefaults.standard.set(data, forKey: Self.zonesKey)
        }
    }
}
