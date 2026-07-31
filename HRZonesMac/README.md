# HRZones

**A macOS app that analyzes your Apple Health data and tells you whether your training is actually easy enough.**

HRZones parses the Health export from your iPhone, matches every heart-rate sample to your workouts, and shows how your training time splits across five heart-rate zones — with a focus on the question endurance athletes care about most: *how much of my training is really in Zone 2?*

Built with SwiftUI and Swift Charts. Runs entirely on your Mac. No accounts, no network access, no data leaves your machine.

<!-- Add a screenshot: docs/screenshot.png -->
![HRZones dashboard](docs/screenshot.png)

## Features

- **Zone 2 target ring** — tracks the share of your training in Zone 2 against an 80% goal, and tells you exactly how many more Zone 2 minutes would get you there
- **Weekly volume goal** — progress toward an optimal weekly Zone 2 range (default 150–180 min, editable), shown as actual minutes in Week view and as a per-week average in Month view
- **Daily stacked chart** — time in each zone, per day, for the past week or month
- **Zone distribution** — percentage and total time per zone
- **Zone 1 handling** — by default, Zone 1 (warmup/cooldown/recovery) is treated as neutral and excluded from the target math, matching how 80/20 training is usually interpreted; a checkbox switches to the strict all-time metric
- **Fully editable zones** — Apple's Health export does *not* include the zone boundaries configured on your Watch, so HRZones estimates them from max HR (220 − age, read from your export) and lets you override every boundary manually, with gap/overlap validation
- **Fast** — a byte-level streaming parser chews through multi-gigabyte `export.xml` files in seconds (10–30× faster than Foundation's `XMLParser`), results are cached, and the app remembers your last export and reloads it automatically at launch

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15 or later to build
- An iPhone with Health data (Apple Watch heart-rate data during workouts is what gets analyzed)

No Apple Developer Program membership is needed — the app signs with "Sign to Run Locally."

## Building

1. Clone the repo:
   ```bash
   git clone https://github.com/hanleyp/HRZones.git
   cd HRZones
   ```
2. Open `HRZonesMac.xcodeproj` in Xcode.
3. Check two settings under the target's **Signing & Capabilities**:
   - Signing: "Automatically manage signing" with your personal team, or Signing Certificate "Sign to Run Locally"
   - If **App Sandbox** is enabled: set **File Access → User Selected File → Read Only** (required for the file picker)
4. Build and run (⌘R).

### Troubleshooting the build

- **CodeSign fails with "invalid or unsupported format" or "detritus" errors** — stale build products or quarantine attributes from downloaded files. Run:
  ```bash
  xattr -cr .            # from the project root
  ```
  then Product → Clean Build Folder (⇧⌘K) and rebuild.
- **`ObservableObject` conformance errors** — make sure you're building the whole project, not a single file; all five Swift files belong to the app target.

## Using the app

### 1. Export your Health data (on the iPhone)

Health app → tap your **profile picture** (top right) → **Export All Health Data**. This produces `export.zip` — it can take a few minutes and be large (0.5–2 GB is normal).

### 2. Get it to the Mac

AirDrop the zip to your Mac, or save it to iCloud Drive.

### 3. Open it in HRZones

Click **Open export.zip / folder…** or drag any of these onto the window:

- `export.zip` (the app unzips it for you)
- `export.xml`
- the unzipped `apple_health_export` folder

The app remembers whatever you opened and reloads it automatically next launch. Parsed results are cached against the file's size and modification date, so reopening the same export is instant; a new export invalidates the cache and re-parses.

**Tip — lowest-friction refresh loop:** unzip once, keep the `apple_health_export` folder somewhere stable, and open it once. From then on, just replace the `export.xml` inside that folder with each new export — the app auto-loads the folder at launch and notices the file changed.

### 4. Set your zones

Click the sliders icon to open the zone editor:

- **Max HR** defaults to 220 − your age (read from the export's date of birth). Adjust it, or edit each zone's low/high BPM directly.
- To match your Apple Watch exactly, copy the values from **Watch app → Workout → Heart Rate Zones** (the export doesn't contain them).
- The editor warns about gaps and overlaps between zones.
- The **weekly Zone 2 goal** range (default 150–180 min) is editable here too.

### 5. Read the dashboard

- **Week / Month** toggle switches the analysis window (anchored to the export's timestamp, so a few-days-old export still computes "past week" correctly).
- **Zone 2 Target ring** — Zone 2 as a share of Zone 2–5 time by default. The checkbox underneath switches to counting Zone 1 in the denominator.
- **Weekly Zone 2 Volume** — actual trailing-7-day minutes in Week view; average minutes per week in Month view. The shaded band marks your optimal range.
- **Daily Time in Zones** — stacked bars, all five zones (Zone 1 is always shown here even when excluded from the target).
- **Zone Distribution** — per-zone totals; percentages respect the Zone 1 setting.

## How the numbers are computed

- Only heart rate recorded **during workouts** counts. All-day background HR is excluded.
- Each HR sample "owns" the time until the next sample, capped at 60 seconds so sensor dropouts don't inflate a zone; the last sample owns time to the workout's end.
- Samples that fall in a gap between zones (possible after manual edits) are not counted — the editor flags gaps so you can close them.
- The parser keeps only the last 31 days of samples in memory, which is what makes multi-GB exports fast and light.

### Why exclude Zone 1 by default?

The "80% easy" guideline from polarized-training research splits training into low intensity (Zones 1–2) versus moderate-plus (Zones 3–5). Zone 1 time — warmups, cooldowns, recovery spinning — is easy by definition, so counting it *against* a Zone 2 target penalizes good practice. The default metric therefore asks: *of the time I spent actually training (Z2–5), how much stayed in Zone 2?* Purists can flip the checkbox for the strict version.

## Privacy

Your Health export contains sensitive personal data. HRZones:

- makes **no network requests** of any kind
- stores only derived results (heart-rate timestamps/BPM from the last 31 days and workout intervals) in a local cache under `~/Library/Application Support/`
- keeps a security-scoped bookmark to your export's location so it can reload it at launch

Delete the cache and bookmark at any time by removing the app's Application Support folder and its `UserDefaults` domain. Be mindful not to commit your `export.zip`/`export.xml` to any repository.

## Project structure

```
HRZonesMac/
├── HRZonesMacApp.swift       # App entry point
├── ContentView.swift         # Dashboard: ring, goal bar, charts, distribution
├── ZoneEditorView.swift      # Zone boundary + goal editor with validation
├── ZoneModels.swift          # Zone definitions, defaults, persistence
└── HealthExportStore.swift   # Zip/folder handling, byte-level XML parser,
                              # caching, bookmark restore, time-in-zone math
```

## Limitations

- The export is a snapshot — re-export from the phone to refresh data.
- HR-based zones drift from power-based zones (e.g., Peloton Power Zones): holding steady Zone 2 *watts*, your heart rate climbs late in a ride (cardiac drift), so HR-Zone-2 time will read slightly lower than power-Zone-2 effort. This is physiology, not a bug.
- The 220 − age max-HR formula is a population estimate; if you know your actual max HR or lactate threshold, set the zones manually.
- Analysis covers the last 31 days only, by design.

## Disclaimer

HRZones is a hobby project for visualizing your own training data. It is not a medical device and provides no medical advice. Consult a professional for training or health decisions.

## License

See [LICENSE](LICENSE).
