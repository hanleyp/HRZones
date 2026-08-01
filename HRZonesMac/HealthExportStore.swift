//
//  HealthExportStore.swift
//  HRZonesMac
//
//  Parses the Apple Health export and computes time-in-zone per day.
//
//  Performance design (exports are routinely 0.5–2 GB of XML):
//  1. FAST PATH: a byte-level line scanner that never builds an XML tree
//     and never allocates Strings for the millions of irrelevant records —
//     typically 10–30x faster than Foundation's XMLParser.
//  2. RESULT CACHE: parsed results are cached keyed on the file's
//     size + modification date, so reopening the same export is instant.
//  3. REMEMBERED SOURCE: a security-scoped bookmark to the last opened
//     zip/xml/folder is saved, and the app reloads it automatically at
//     launch. Dropping the already-unzipped apple_health_export folder
//     (or export.xml itself) also skips the unzip step entirely.
//  4. FALLBACK: if the fast scanner finds nothing (format drift), it
//     falls back to the standard XMLParser.
//

import Foundation
import Combine

// MARK: - Result types

struct HRSample {
    let date: Date
    let bpm: Double
}

struct WorkoutRecord: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
    let activity: String
}

struct DayZoneBreakdown: Identifiable {
    var id: Date { day }
    let day: Date
    var secondsPerZone: [Int: TimeInterval]

    var totalSeconds: TimeInterval { secondsPerZone.values.reduce(0, +) }
}

struct ZoneSummary {
    var secondsPerZone: [Int: TimeInterval] = [:]
    var totalSeconds: TimeInterval { secondsPerZone.values.reduce(0, +) }

    func fraction(zone id: Int) -> Double {
        guard totalSeconds > 0 else { return 0 }
        return (secondsPerZone[id] ?? 0) / totalSeconds
    }
}

enum AnalysisRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    var id: String { rawValue }

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        }
    }
}

enum LoadState: Equatable {
    case empty
    case loading(String)
    case ready
    case failed(String)
}

// MARK: - Store

@MainActor
final class HealthExportStore: ObservableObject {

    @Published var state: LoadState = .empty
    @Published var dailyBreakdowns: [DayZoneBreakdown] = []
    @Published var summary = ZoneSummary()
    @Published var workoutCount = 0
    @Published var exportDate: Date?
    @Published var ageFromExport: Int?
    @Published var sourceFileName: String?

    private var samples: [HRSample] = []
    private var workouts: [WorkoutRecord] = []

    private static let bookmarkKey = "hrzones.sourceBookmark"

    // MARK: Loading

    /// Re-opens the last-used export automatically (called at launch).
    func loadLastSourceIfAvailable() {
        guard state == .empty,
              let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        load(url: url, isFromBookmark: true)
    }

    func load(url: URL, isFromBookmark: Bool = false) {
        state = .loading("Opening \(url.lastPathComponent)…")
        sourceFileName = url.lastPathComponent

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            do {
                // Remember this source for next launch (bookmark must be
                // created while we hold security-scoped access).
                if !isFromBookmark,
                   let bookmark = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil) {
                    UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
                }

                let xmlURL = try Self.resolveXML(from: url) { status in
                    Task { @MainActor in self.state = .loading(status) }
                }

                let result: ParseResult
                if let cached = Self.loadCache(for: xmlURL) {
                    Task { @MainActor in self.state = .loading("Loading cached results…") }
                    result = cached
                } else {
                    switch xmlURL.pathExtension.lowercased() {
                    case "json":
                        Task { @MainActor in self.state = .loading("Reading Health Auto Export JSON…") }
                        result = try Self.parseHealthAutoExportJSON(url: xmlURL)
                    case "csv":
                        Task { @MainActor in self.state = .loading("Reading Health Auto Export CSV…") }
                        result = try Self.parseHealthAutoExportCSV(url: xmlURL)
                    default:
                        result = try Self.parseFast(xmlURL: xmlURL) { fractionDone in
                            Task { @MainActor in
                                self.state = .loading("Parsing export… \(Int(fractionDone * 100))%")
                            }
                        }
                    }
                    Self.saveCache(result, for: xmlURL)
                }

                await MainActor.run {
                    self.samples = result.samples.sorted { $0.date < $1.date }
                    self.workouts = result.workouts
                    self.exportDate = result.exportDate
                    self.ageFromExport = result.age
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Accepts export.zip, export.xml, or the unzipped apple_health_export
    /// folder (dropping the folder skips the unzip entirely — fastest).
    nonisolated static func resolveXML(from url: URL, status: @escaping (String) -> Void) throws -> URL {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            var candidates = [
                url.appendingPathComponent("export.xml"),
                url.appendingPathComponent("apple_health_export/export.xml"),
            ].filter { FileManager.default.fileExists(atPath: $0.path) }

            // Health Auto Export writes timestamped .json/.csv files —
            // include any found at the folder's top level.
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
                candidates += entries.filter {
                    ["json", "csv"].contains($0.pathExtension.lowercased())
                }
            }
            guard !candidates.isEmpty else {
                throw NSError(domain: "HRZones", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "No export found in that folder. Expected a Health Auto Export .json/.csv, export.xml, or an apple_health_export folder."
                ])
            }
            // Prefer whichever data file is freshest.
            func modified(_ u: URL) -> TimeInterval {
                let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
                return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            }
            return candidates.max(by: { modified($0) < modified($1) })!
        }

        switch url.pathExtension.lowercased() {
        case "xml", "json", "csv":
            return url
        case "zip":
            status("Unzipping \(url.lastPathComponent)…")
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("HRZonesExport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", url.path, "-d", tempDir.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "HRZones", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't unzip the export. Unzip it in Finder and open the apple_health_export folder instead."
                ])
            }
            let candidates = [
                tempDir.appendingPathComponent("apple_health_export/export.xml"),
                tempDir.appendingPathComponent("export.xml"),
            ]
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                return found
            }
            throw NSError(domain: "HRZones", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "export.xml not found inside the zip. Is this a Health export?"
            ])
        default:
            throw NSError(domain: "HRZones", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Please choose a Health Auto Export .json/.csv file, export.zip, export.xml, or the apple_health_export folder."
            ])
        }
    }

    // MARK: Analysis (unchanged)

    func analyze(range: AnalysisRange, zones: [HRZone]) {
        guard state == .ready else { return }

        let calendar = Calendar.current
        let anchor = exportDate ?? Date()
        let endDate = anchor
        guard let startDate = calendar.date(byAdding: .day, value: -range.days,
                                            to: calendar.startOfDay(for: endDate)) else { return }

        let relevantWorkouts = workouts.filter { $0.end >= startDate && $0.start <= endDate }
        workoutCount = relevantWorkouts.count

        var perDay: [Date: [Int: TimeInterval]] = [:]

        for workout in relevantWorkouts {
            let workoutSamples = samplesIn(start: workout.start, end: workout.end)
            let zoneSeconds = Self.timeInZones(samples: workoutSamples,
                                               workoutEnd: workout.end, zones: zones)
            let day = calendar.startOfDay(for: workout.start)
            for (zoneID, secs) in zoneSeconds {
                perDay[day, default: [:]][zoneID, default: 0] += secs
            }
        }

        var breakdowns: [DayZoneBreakdown] = []
        var cursor = calendar.startOfDay(for: startDate)
        let last = calendar.startOfDay(for: endDate)
        while cursor <= last {
            breakdowns.append(DayZoneBreakdown(day: cursor, secondsPerZone: perDay[cursor] ?? [:]))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
        }
        dailyBreakdowns = breakdowns

        var total = ZoneSummary()
        for (_, zoneMap) in perDay {
            for (zoneID, secs) in zoneMap {
                total.secondsPerZone[zoneID, default: 0] += secs
            }
        }
        summary = total
    }

    private func samplesIn(start: Date, end: Date) -> [HRSample] {
        guard !samples.isEmpty else { return [] }
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].date < start { lo = mid + 1 } else { hi = mid }
        }
        var result: [HRSample] = []
        var i = lo
        while i < samples.count && samples[i].date <= end {
            result.append(samples[i])
            i += 1
        }
        return result
    }

    static func timeInZones(
        samples: [HRSample],
        workoutEnd: Date,
        zones: [HRZone],
        maxGap: TimeInterval = 60
    ) -> [Int: TimeInterval] {
        guard !samples.isEmpty else { return [:] }
        var result: [Int: TimeInterval] = [:]
        for (index, sample) in samples.enumerated() {
            let nextDate = index + 1 < samples.count ? samples[index + 1].date : workoutEnd
            let interval = min(max(nextDate.timeIntervalSince(sample.date), 0), maxGap)
            if let zone = zones.first(where: { $0.contains(sample.bpm) }) {
                result[zone.id, default: 0] += interval
            }
        }
        return result
    }

    // MARK: Parse result + cache

    struct ParseResult {
        var samples: [HRSample]
        var workouts: [WorkoutRecord]
        var exportDate: Date?
        var age: Int?
    }

    private struct CachePayload: Codable {
        var version = 2
        var fileSize: Int64
        var fileModified: TimeInterval
        var sampleTimes: [Double]
        var sampleBPMs: [Double]
        var workoutStarts: [Double]
        var workoutEnds: [Double]
        var workoutActivities: [String]
        var exportDate: Double?
        var age: Int?
    }

    nonisolated private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HRZonesMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("exportCache.json")
    }

    nonisolated private static func fileStamp(_ url: URL) -> (size: Int64, modified: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return (size, modified.timeIntervalSince1970)
    }

    nonisolated static func loadCache(for xmlURL: URL) -> ParseResult? {
        guard let stamp = fileStamp(xmlURL),
              let data = try? Data(contentsOf: cacheURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data),
              payload.version == 2,
              payload.fileSize == stamp.size,
              abs(payload.fileModified - stamp.modified) < 1 else { return nil }

        let samples = zip(payload.sampleTimes, payload.sampleBPMs).map {
            HRSample(date: Date(timeIntervalSince1970: $0), bpm: $1)
        }
        var workouts: [WorkoutRecord] = []
        for i in payload.workoutStarts.indices {
            workouts.append(WorkoutRecord(
                start: Date(timeIntervalSince1970: payload.workoutStarts[i]),
                end: Date(timeIntervalSince1970: payload.workoutEnds[i]),
                activity: i < payload.workoutActivities.count ? payload.workoutActivities[i] : ""
            ))
        }
        return ParseResult(
            samples: samples,
            workouts: workouts,
            exportDate: payload.exportDate.map(Date.init(timeIntervalSince1970:)),
            age: payload.age
        )
    }

    nonisolated static func saveCache(_ result: ParseResult, for xmlURL: URL) {
        guard let stamp = fileStamp(xmlURL) else { return }
        let payload = CachePayload(
            fileSize: stamp.size,
            fileModified: stamp.modified,
            sampleTimes: result.samples.map { $0.date.timeIntervalSince1970 },
            sampleBPMs: result.samples.map { $0.bpm },
            workoutStarts: result.workouts.map { $0.start.timeIntervalSince1970 },
            workoutEnds: result.workouts.map { $0.end.timeIntervalSince1970 },
            workoutActivities: result.workouts.map { $0.activity },
            exportDate: result.exportDate?.timeIntervalSince1970,
            age: result.age
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    // MARK: Health Auto Export (JSON + CSV)

    // Parses exports from the "Health Auto Export - JSON+CSV" iOS app
    // (healthyapps.dev). JSON schema per the developer's documentation:
    //   { "data": { "metrics": [ { "name": "heart_rate", "units": …,
    //       "data": [ { "date": "yyyy-MM-dd HH:mm:ss Z",
    //                   "Min": n, "Avg": n, "Max": n } ] } ],
    //     "workouts": [ { "name": …, "start": …, "end": …,
    //                     "heartRateData": [ { "date": …, "Avg"/"qty": n } ] } ] } }
    // Field casing and value keys vary across app/API versions, so lookups
    // are tolerant (Avg/avg/qty), and dates accept both the space-separated
    // and ISO 8601 forms.

    nonisolated static func parseHealthAutoExportJSON(url: URL) throws -> ParseResult {
        let raw: Data
        do { raw = try Data(contentsOf: url) } catch {
            throw NSError(domain: "HRZones", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read \(url.lastPathComponent)."
            ])
        }
        guard let rootAny = try? JSONSerialization.jsonObject(with: raw),
              let root = rootAny as? [String: Any] else {
            throw NSError(domain: "HRZones", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't valid JSON."
            ])
        }
        let container = (root["data"] as? [String: Any]) ?? root
        let cutoff = Date().addingTimeInterval(-31 * 86400)

        func parseDate(_ any: Any?) -> Date? {
            guard let s = any as? String else { return nil }
            return FastHealthDate.parse(s)
        }
        func number(_ any: Any?) -> Double? {
            if let n = any as? Double { return n }
            if let n = any as? Int { return Double(n) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }
        /// Heart-rate entries carry Min/Avg/Max; other variants use qty.
        func hrValue(_ entry: [String: Any]) -> Double? {
            for key in ["Avg", "avg", "qty", "value"] {
                if let v = number(entry[key]) { return v }
            }
            return nil
        }
        /// Matches "heart_rate" / "Heart Rate" while excluding resting,
        /// walking-average, variability, and recovery metrics.
        func isInstantHeartRateMetric(_ name: String) -> Bool {
            let normalized = name.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard normalized.contains("heartrate") else { return false }
            for excluded in ["resting", "walking", "variability", "recovery", "notification"] {
                if normalized.contains(excluded) { return false }
            }
            return true
        }

        var samples: [HRSample] = []
        var workouts: [WorkoutRecord] = []

        if let metrics = container["metrics"] as? [[String: Any]] {
            for metric in metrics {
                guard isInstantHeartRateMetric(metric["name"] as? String ?? "") else { continue }
                for entry in metric["data"] as? [[String: Any]] ?? [] {
                    guard let date = parseDate(entry["date"]), date >= cutoff,
                          let bpm = hrValue(entry) else { continue }
                    samples.append(HRSample(date: date, bpm: bpm))
                }
            }
        }

        if let workoutArray = container["workouts"] as? [[String: Any]] {
            for w in workoutArray {
                guard let start = parseDate(w["start"]),
                      let end = parseDate(w["end"]),
                      end >= cutoff, end > start else { continue }
                let name = (w["name"] as? String) ?? "Workout"
                workouts.append(WorkoutRecord(start: start, end: end, activity: name))

                // Workouts carry their own per-sample heart-rate arrays —
                // the highest-resolution data in the export.
                for key in ["heartRateData", "heartRateRecovery"] where key == "heartRateData" {
                    for entry in w[key] as? [[String: Any]] ?? [] {
                        guard let date = parseDate(entry["date"]), date >= cutoff,
                              let bpm = hrValue(entry) else { continue }
                        samples.append(HRSample(date: date, bpm: bpm))
                    }
                }
            }
        }

        return try finalizeHealthAutoExport(samples: samples, workouts: workouts, source: url)
    }

    /// Tolerant CSV reader for Health Auto Export heart-rate CSVs: finds
    /// the date column and the best value column (Avg preferred) from the
    /// header row, whatever the exact header wording.
    nonisolated static func parseHealthAutoExportCSV(url: URL) throws -> ParseResult {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "HRZones", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read \(url.lastPathComponent)."
            ])
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else {
            throw NSError(domain: "HRZones", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) doesn't look like a Health Auto Export CSV."
            ])
        }

        func cells(_ line: String) -> [String] {
            line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        let header = cells(lines[0]).map { $0.lowercased() }
        guard let dateCol = header.firstIndex(where: { $0.contains("date") }) else {
            throw NSError(domain: "HRZones", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "No date column found in \(url.lastPathComponent). Export the Heart Rate metric as CSV from Health Auto Export."
            ])
        }
        let valueCol = header.firstIndex(where: { $0.contains("avg") })
            ?? header.firstIndex(where: { $0.contains("qty") })
            ?? header.firstIndex(where: { $0.contains("heart rate") && !$0.contains("date") })
            ?? (dateCol == 0 ? 1 : 0)

        let cutoff = Date().addingTimeInterval(-31 * 86400)
        var samples: [HRSample] = []
        for line in lines.dropFirst() {
            let row = cells(line)
            guard row.count > max(dateCol, valueCol),
                  let date = FastHealthDate.parse(row[dateCol]), date >= cutoff,
                  let bpm = lenientDouble(row[valueCol]) else { continue }
            samples.append(HRSample(date: date, bpm: bpm))
        }

        return try finalizeHealthAutoExport(samples: samples, workouts: [], source: url)
    }

    /// Shared tail: dedupe/sort samples, infer workouts when the export
    /// didn't include any, and anchor the analysis window to the data.
    nonisolated private static func finalizeHealthAutoExport(
        samples: [HRSample], workouts: [WorkoutRecord], source: URL
    ) throws -> ParseResult {
        guard !samples.isEmpty else {
            throw NSError(domain: "HRZones", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "No heart-rate data found in \(source.lastPathComponent). In Health Auto Export, enable the Heart Rate metric (and Export Workouts), then export again."
            ])
        }
        // Dedupe by whole-second timestamp (metrics + workout HR overlap).
        var byKey: [Int64: Double] = [:]
        for s in samples {
            byKey[Int64(s.date.timeIntervalSince1970.rounded())] = s.bpm
        }
        let deduped = byKey.keys.sorted().map {
            HRSample(date: Date(timeIntervalSince1970: Double($0)), bpm: byKey[$0]!)
        }

        var finalWorkouts = workouts
        if finalWorkouts.isEmpty {
            finalWorkouts = inferWorkouts(from: deduped)
        }
        let newestWorkoutEnd = finalWorkouts.map(\.end).max()
        let anchor = max(deduped.last!.date, newestWorkoutEnd ?? .distantPast)

        return ParseResult(samples: deduped, workouts: finalWorkouts,
                           exportDate: anchor, age: nil)
    }

    /// Parses "67", "67.5", or "67,5" (decimal-comma locales).
    nonisolated static func lenientDouble(_ s: String) -> Double? {
        let numeric = s.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard !numeric.isEmpty else { return nil }
        if numeric.contains(","), !numeric.contains(".") {
            return Double(numeric.replacingOccurrences(of: ",", with: "."))
        }
        if numeric.contains(",") {
            return Double(numeric.replacingOccurrences(of: ",", with: ""))
        }
        return Double(numeric)
    }

    /// Clusters densely-sampled heart-rate stretches into workout sessions
    /// for exports that don't include workouts. Thresholds accommodate
    /// per-minute aggregated data: a session continues while consecutive
    /// samples are ≤ 150 s apart, and counts as a workout if it lasts
    /// ≥ 10 min with ≥ 8 samples averaging ≤ 75 s apart — far denser than
    /// background sampling (every 3–10 min), so false positives are rare.
    nonisolated static func inferWorkouts(
        from sortedSamples: [HRSample],
        maxGap: TimeInterval = 150,
        minDuration: TimeInterval = 10 * 60,
        minSamples: Int = 8,
        maxAverageCadence: TimeInterval = 75
    ) -> [WorkoutRecord] {
        guard sortedSamples.count > 1 else { return [] }
        var workouts: [WorkoutRecord] = []
        var clusterStart = 0

        func closeCluster(endIndex: Int) {
            let count = endIndex - clusterStart + 1
            guard count >= minSamples else { return }
            let start = sortedSamples[clusterStart].date
            let end = sortedSamples[endIndex].date
            let duration = end.timeIntervalSince(start)
            guard duration >= minDuration,
                  duration / Double(count) <= maxAverageCadence else { return }
            workouts.append(WorkoutRecord(start: start, end: end, activity: "Workout"))
        }

        for i in 1..<sortedSamples.count {
            let gap = sortedSamples[i].date.timeIntervalSince(sortedSamples[i - 1].date)
            if gap > maxGap {
                closeCluster(endIndex: i - 1)
                clusterStart = i
            }
        }
        closeCluster(endIndex: sortedSamples.count - 1)
        return workouts
    }

    // MARK: Fast byte-level parser

    /// Streams the file in 8 MB chunks and scans line-by-line at the byte
    /// level. Never builds an XML tree; never allocates Strings for the
    /// millions of non-heart-rate records.
    nonisolated static func parseFast(
        xmlURL: URL,
        progress: @escaping (Double) -> Void
    ) throws -> ParseResult {
        guard let handle = try? FileHandle(forReadingFrom: xmlURL) else {
            throw NSError(domain: "HRZones", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't open \(xmlURL.lastPathComponent)."
            ])
        }
        defer { try? handle.close() }

        let totalBytes = Double(fileStamp(xmlURL)?.size ?? 0)
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        var scanner = ExportLineScanner(cutoff: cutoff)

        let chunkSize = 8 * 1024 * 1024
        var carry = [UInt8]()
        var bytesRead: Double = 0
        var lastReported: Double = -1

        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            bytesRead += Double(chunk.count)

            var buffer = carry
            buffer.append(contentsOf: chunk)

            // Find the last newline; keep the partial tail for next round.
            var lastNewline = -1
            var i = buffer.count - 1
            while i >= 0 {
                if buffer[i] == 0x0A { lastNewline = i; break }
                i -= 1
            }
            if lastNewline >= 0 {
                buffer.withUnsafeBufferPointer { ptr in
                    scanner.scan(ptr.baseAddress!, count: lastNewline + 1)
                }
                carry = Array(buffer[(lastNewline + 1)...])
            } else {
                carry = buffer
            }

            if totalBytes > 0 {
                let fraction = bytesRead / totalBytes
                if fraction - lastReported >= 0.02 {
                    lastReported = fraction
                    progress(min(fraction, 1))
                }
            }
        }
        // Final partial line (files normally end with a newline, but be safe).
        if !carry.isEmpty {
            carry.append(0x0A)
            carry.withUnsafeBufferPointer { ptr in
                scanner.scan(ptr.baseAddress!, count: carry.count)
            }
        }

        // Fallback: if the byte scanner found nothing at all, the format may
        // have changed — try the standard XML parser before giving up.
        if scanner.samples.isEmpty && scanner.workouts.isEmpty {
            return try parseWithXMLParser(xmlURL: xmlURL)
        }

        return ParseResult(
            samples: scanner.samples,
            workouts: scanner.workouts,
            exportDate: scanner.exportDate,
            age: scanner.age
        )
    }

    // MARK: XMLParser fallback

    nonisolated static func parseWithXMLParser(xmlURL: URL) throws -> ParseResult {
        guard let stream = InputStream(url: xmlURL) else {
            throw NSError(domain: "HRZones", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't open \(xmlURL.lastPathComponent)."
            ])
        }
        let delegate = ExportParserDelegate()
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "XML parse error"
            throw NSError(domain: "HRZones", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Failed to parse export.xml: \(message)"
            ])
        }
        return ParseResult(
            samples: delegate.samples,
            workouts: delegate.workouts,
            exportDate: delegate.exportDate,
            age: delegate.age
        )
    }
}

// MARK: - Byte-level line scanner

private struct ExportLineScanner {

    let cutoff: Date
    var samples: [HRSample] = []
    var workouts: [WorkoutRecord] = []
    var exportDate: Date?
    var age: Int?

    // Needles as byte arrays (built once).
    private let recordTag = [UInt8]("<Record ".utf8)
    private let workoutTag = [UInt8]("<Workout ".utf8)
    private let exportDateTag = [UInt8]("<ExportDate ".utf8)
    private let meTag = [UInt8]("<Me ".utf8)
    private let hrType = [UInt8]("type=\"HKQuantityTypeIdentifierHeartRate\"".utf8)
    private let startDateAttr = [UInt8](" startDate=\"".utf8)
    private let endDateAttr = [UInt8](" endDate=\"".utf8)
    private let valueAttr = [UInt8](" value=\"".utf8)
    private let activityAttr = [UInt8]("workoutActivityType=\"".utf8)
    private let dobAttr = [UInt8]("HKCharacteristicTypeIdentifierDateOfBirth=\"".utf8)
    private let hkActivityPrefix = "HKWorkoutActivityType"

    init(cutoff: Date) {
        self.cutoff = cutoff
    }

    mutating func scan(_ base: UnsafePointer<UInt8>, count: Int) {
        var lineStart = 0
        var i = 0
        while i < count {
            if base[i] == 0x0A {
                processLine(base + lineStart, length: i - lineStart)
                lineStart = i + 1
            }
            i += 1
        }
    }

    private mutating func processLine(_ line: UnsafePointer<UInt8>, length: Int) {
        // Skip leading whitespace to the '<'
        var start = 0
        while start < length, line[start] == 0x20 || line[start] == 0x09 { start += 1 }
        guard start < length, line[start] == 0x3C /* '<' */ else { return }
        let tag = line + start
        let tagLen = length - start

        if hasPrefix(tag, tagLen, recordTag) {
            guard contains(tag, tagLen, hrType),
                  let dateRange = attributeValue(tag, tagLen, startDateAttr),
                  let date = FastHealthDate.parse(bytes: tag + dateRange.offset, count: dateRange.length),
                  date >= cutoff,
                  let valueRange = attributeValue(tag, tagLen, valueAttr),
                  let bpm = parseDouble(tag + valueRange.offset, valueRange.length)
            else { return }
            samples.append(HRSample(date: date, bpm: bpm))

        } else if hasPrefix(tag, tagLen, workoutTag) {
            guard let startRange = attributeValue(tag, tagLen, startDateAttr),
                  let endRange = attributeValue(tag, tagLen, endDateAttr),
                  let start = FastHealthDate.parse(bytes: tag + startRange.offset, count: startRange.length),
                  let end = FastHealthDate.parse(bytes: tag + endRange.offset, count: endRange.length),
                  end >= cutoff
            else { return }
            var activity = ""
            if let actRange = attributeValue(tag, tagLen, activityAttr) {
                activity = String(decoding: UnsafeBufferPointer(start: tag + actRange.offset, count: actRange.length), as: UTF8.self)
                if activity.hasPrefix(hkActivityPrefix) {
                    activity = String(activity.dropFirst(hkActivityPrefix.count))
                }
            }
            workouts.append(WorkoutRecord(start: start, end: end, activity: activity))

        } else if exportDate == nil, hasPrefix(tag, tagLen, exportDateTag) {
            if let range = attributeValue(tag, tagLen, valueAttr) {
                exportDate = FastHealthDate.parse(bytes: tag + range.offset, count: range.length)
            }

        } else if age == nil, hasPrefix(tag, tagLen, meTag) {
            if let range = attributeValue(tag, tagLen, dobAttr), range.length >= 4 {
                var year = 0
                for k in 0..<4 {
                    let b = tag[range.offset + k]
                    guard b >= 48, b <= 57 else { return }
                    year = year * 10 + Int(b - 48)
                }
                let currentYear = Calendar.current.component(.year, from: Date())
                let computed = currentYear - year
                if (10...110).contains(computed) { age = computed }
            }
        }
    }

    // MARK: byte helpers

    private func hasPrefix(_ p: UnsafePointer<UInt8>, _ len: Int, _ needle: [UInt8]) -> Bool {
        guard len >= needle.count else { return false }
        for i in needle.indices where p[i] != needle[i] { return false }
        return true
    }

    private func contains(_ p: UnsafePointer<UInt8>, _ len: Int, _ needle: [UInt8]) -> Bool {
        indexOf(p, len, needle) != nil
    }

    private func indexOf(_ p: UnsafePointer<UInt8>, _ len: Int, _ needle: [UInt8]) -> Int? {
        let n = needle.count
        guard n > 0, len >= n else { return nil }
        let first = needle[0]
        var i = 0
        let limit = len - n
        while i <= limit {
            if p[i] == first {
                var j = 1
                while j < n, p[i + j] == needle[j] { j += 1 }
                if j == n { return i }
            }
            i += 1
        }
        return nil
    }

    /// Returns the (offset, length) of the value inside `attr="value"`.
    private func attributeValue(_ p: UnsafePointer<UInt8>, _ len: Int, _ needle: [UInt8]) -> (offset: Int, length: Int)? {
        guard let idx = indexOf(p, len, needle) else { return nil }
        let valueStart = idx + needle.count
        var end = valueStart
        while end < len, p[end] != 0x22 /* '"' */ { end += 1 }
        guard end < len else { return nil }
        return (valueStart, end - valueStart)
    }

    /// Parses "123" or "123.5" without allocating a String.
    private func parseDouble(_ p: UnsafePointer<UInt8>, _ len: Int) -> Double? {
        var intPart = 0.0
        var i = 0
        var sawDigit = false
        while i < len, p[i] >= 48, p[i] <= 57 {
            intPart = intPart * 10 + Double(p[i] - 48)
            sawDigit = true
            i += 1
        }
        guard sawDigit else { return nil }
        if i < len, p[i] == 0x2E /* '.' */ {
            i += 1
            var frac = 0.0
            var scale = 0.1
            while i < len, p[i] >= 48, p[i] <= 57 {
                frac += Double(p[i] - 48) * scale
                scale /= 10
                i += 1
            }
            return intPart + frac
        }
        return intPart
    }
}

// MARK: - XMLParser fallback delegate

private final class ExportParserDelegate: NSObject, XMLParserDelegate {

    var samples: [HRSample] = []
    var workouts: [WorkoutRecord] = []
    var exportDate: Date?
    var age: Int?

    private let cutoff = Date().addingTimeInterval(-31 * 86400)

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "Record":
            guard attributeDict["type"] == "HKQuantityTypeIdentifierHeartRate",
                  let dateStr = attributeDict["startDate"],
                  let date = FastHealthDate.parse(dateStr),
                  date >= cutoff,
                  let valueStr = attributeDict["value"],
                  let bpm = Double(valueStr) else { return }
            samples.append(HRSample(date: date, bpm: bpm))

        case "Workout":
            guard let startStr = attributeDict["startDate"],
                  let endStr = attributeDict["endDate"],
                  let start = FastHealthDate.parse(startStr),
                  let end = FastHealthDate.parse(endStr),
                  end >= cutoff else { return }
            let rawActivity = attributeDict["workoutActivityType"] ?? ""
            let activity = rawActivity.replacingOccurrences(of: "HKWorkoutActivityType", with: "")
            workouts.append(WorkoutRecord(start: start, end: end, activity: activity))

        case "ExportDate":
            if let value = attributeDict["value"] {
                exportDate = FastHealthDate.parse(value)
            }

        case "Me":
            if let dob = attributeDict["HKCharacteristicTypeIdentifierDateOfBirth"],
               dob.count >= 4, let birthYear = Int(dob.prefix(4)) {
                let currentYear = Calendar.current.component(.year, from: Date())
                let computed = currentYear - birthYear
                if (10...110).contains(computed) { age = computed }
            }

        default:
            break
        }
    }
}

// MARK: - Fast date parsing

/// Parses Health-export timestamps "2026-07-30 07:12:34 -0700" without
/// DateFormatter, from either a String or raw bytes.
enum FastHealthDate {

    static func parse(_ s: String) -> Date? {
        var bytes = Array(s.utf8)
        return bytes.withUnsafeBufferPointer { ptr in
            parse(bytes: ptr.baseAddress!, count: ptr.count)
        }
    }

    /// Handles the Apple/Health Auto Export format "2026-07-30 07:12:34 -0700"
    /// plus ISO 8601 variants "2026-07-30T07:12:34-07:00" / "…Z", with
    /// optional fractional seconds.
    static func parse(bytes p: UnsafePointer<UInt8>, count: Int) -> Date? {
        guard count >= 19 else { return nil }

        func digit(_ i: Int) -> Int? {
            let b = p[i]
            guard b >= 48, b <= 57 else { return nil }
            return Int(b - 48)
        }
        func int2(_ i: Int) -> Int? {
            guard i + 1 < count, let a = digit(i), let b = digit(i + 1) else { return nil }
            return a * 10 + b
        }
        func int4(_ i: Int) -> Int? {
            guard let a = int2(i), let b = int2(i + 2) else { return nil }
            return a * 100 + b
        }

        guard let year = int4(0), let month = int2(5), let day = int2(8),
              let hour = int2(11), let minute = int2(14), let second = int2(17)
        else { return nil }

        // Walk past optional fractional seconds and the optional space
        // before the timezone, then read the offset ("Z", "±HHMM", "±HH:MM").
        var i = 19
        if i < count, p[i] == 0x2E /* '.' */ {
            i += 1
            while i < count, p[i] >= 48, p[i] <= 57 { i += 1 }
        }
        if i < count, p[i] == 0x20 /* ' ' */ { i += 1 }

        var tzSeconds = 0
        if i < count {
            let b = p[i]
            if b == 0x5A /* 'Z' */ {
                tzSeconds = 0
            } else if b == 43 /* '+' */ || b == 45 /* '-' */ {
                let sign = (b == 45) ? -1 : 1
                i += 1
                guard let tzH = int2(i) else { return nil }
                i += 2
                if i < count, p[i] == 0x3A /* ':' */ { i += 1 }
                guard let tzM = int2(i) else { return nil }
                tzSeconds = sign * (tzH * 3600 + tzM * 60)
            } else {
                return nil
            }
        }
        // No timezone at all → treated as UTC.

        let days = daysFromCivil(year: year, month: month, day: day)
        let epoch = TimeInterval(days) * 86400
            + TimeInterval(hour * 3600 + minute * 60 + second)
            - TimeInterval(tzSeconds)
        return Date(timeIntervalSince1970: epoch)
    }

    /// Howard Hinnant's days-from-civil algorithm: days since 1970-01-01.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        if month <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}
