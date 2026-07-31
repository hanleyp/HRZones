# HRZonesMac — Zone 2 Training Tracker for macOS

The macOS version of HRZones. Since Health data doesn't sync to the Mac, this app analyzes the **Health export** you create on your iPhone, then shows time-in-zone for the past week or month and progress toward keeping **80% of training in Zone 2**.

## Why no HealthKit?

HealthKit exists on macOS only in a limited form and your Mac has no copy of your Health database anyway — the data lives on the iPhone. The export file is the supported way to get it onto the Mac, and this app parses it directly (no signing headaches, no device pairing, runs entirely on the Mac Studio).

## Setup

1. Xcode → **File → New → Project → macOS → App**, name it `HRZonesMac`, SwiftUI + Swift. Minimum deployment: **macOS 14**.
2. Delete the generated `ContentView.swift` and App file; add these five files:
   - `HRZonesMacApp.swift`
   - `ZoneModels.swift`
   - `HealthExportStore.swift`
   - `ContentView.swift`
   - `ZoneEditorView.swift`
3. Under **Signing & Capabilities**: signing can stay on "Sign to Run Locally" / your personal team — no paid membership, no device registration needed for a Mac app you run yourself.
   - If **App Sandbox** is enabled (it is by default), set **File Access → User Selected File → Read Only**. (Or remove the sandbox capability entirely for personal use.)
4. Run (⌘R). It launches like any Mac app.

## Getting your data in

1. On the iPhone: **Health app → tap your profile picture (top right) → Export All Health Data**. This produces `export.zip` (can take a few minutes and be quite large).
2. AirDrop it to the Mac (or save to iCloud Drive).
3. In HRZonesMac, click **Open export.zip…** or just drag the zip onto the window. The app unzips it to a temp folder and stream-parses `export.xml`.

Parsing is optimized for huge exports (streaming XML + fast custom date parsing; only the last 31 days of heart-rate samples are kept in memory), so even multi-GB exports load in roughly a minute or less.

## How it works

- **Workouts + heart rate:** The parser pulls every `Workout` element and every `HeartRate` record from the last 31 days, matches HR samples to workout windows, and attributes each sample's time to a zone (interval to next sample, capped at 60 s so sensor gaps don't inflate zones).
- **Week/Month views** are anchored to the export's `ExportDate`, so an export from a few days ago still shows the correct "past week."
- **Zones:** The export does **not** include your Watch's configured zones, so defaults use Apple's own scheme — 50/60/70/80/90% bands of max HR, seeded from 220 − age (age is read from the export's date-of-birth). Use **Edit Zones** to enter your exact Watch values (Watch app → Workout → Heart Rate Zones); edits are validated for gaps/overlaps and persisted.
- **Zone 2 target:** The ring shows Zone 2 share vs. the 80% goal and how many more Zone 2 minutes would get the period to target.

## Notes

- Only heart rate recorded **during workouts** counts — background all-day HR is excluded.
- To refresh data, make a new export on the phone and open it again. (The export is a snapshot, not a live link.)
