# Health Auto Export Setup

HRZones can read exports from **[Health Auto Export – JSON+CSV](https://apps.apple.com/us/app/health-auto-export-json-csv/id1115567069)** (healthyapps.dev), which reliably exports filtered date ranges — no giant Health export, no Shortcuts memory limits — and can run automatically on a schedule.

## One-time iPhone setup (~5 minutes)

1. Install **Health Auto Export** from the App Store and grant it Health access when prompted (Heart Rate and Workouts at minimum).
2. Create an export (as a saved automation if you have the premium tier, or as a manual export otherwise):
   - **Health Metrics:** enable **Heart Rate** only (fewer metrics = smaller, faster files).
   - **Export Workouts:** ON — workout entries carry their own high-resolution heart-rate arrays, which is the best data HRZones can get.
   - **Format:** **JSON** (preferred; CSV also works but only carries the metric samples, so workouts get inferred rather than read).
   - **Date range:** last **31 days** (or "since last export" for scheduled automations).
   - **Aggregation / time grouping:** **Minutes** is the sweet spot — fine enough for accurate zone math, small enough to export instantly. ("Seconds" is even more precise but the developer warns large second-level exports can exceed device memory.)
   - **Destination:** an **iCloud Drive** folder, e.g. `iCloud Drive/HRZones/`.
3. Run the export once.

## Connect to HRZones on the Mac

Open HRZones → **Open export…** → select the exported `.json` (or `.csv`), or select the **folder** — the app then always loads the freshest export inside it, which is ideal for scheduled automations that write timestamped files. The choice is bookmarked and auto-loads at every launch; the cache re-parses only when the data changes.

## How the data is interpreted

- Heart-rate samples come from the `heart_rate` metric **and** from each workout's embedded `heartRateData`, deduplicated by timestamp. Resting/walking-average/HRV/recovery metrics are ignored.
- Workouts come from the export's `workouts` array (name, start, end). If the export contains no workouts (e.g., a CSV, or workouts toggled off), HRZones infers sessions from heart-rate density: runs of samples ≤ 150 s apart lasting ≥ 10 min with average cadence ≤ 75 s. Watch-recorded workouts pass easily; sparse background sampling (every 3–10 min) cannot.
- The Week/Month windows anchor to the newest data point in the file, so a day-old export still computes "past week" correctly.
- Only heart rate recorded during (real or inferred) workouts counts toward zone time.

## Automation tip

With the premium tier, schedule the export daily or weekly to the same iCloud folder and point HRZones at the folder once. Your loop becomes: open HRZones, see fresh data. Nothing else.

## Troubleshooting

- **"No heart-rate data found"** — the Heart Rate metric wasn't enabled, Health access wasn't granted to Health Auto Export, or the date range is empty. Re-check the export configuration.
- **Workout count looks wrong** — if the export lacked workouts, inference is being used: sessions under 10 minutes are skipped, and a >2.5-minute mid-workout pause splits one session into two (harmless for zone totals). Enable **Export Workouts** in the app for exact boundaries and activity names.
- **Old data showing** — the app loads the newest file in the bookmarked folder; confirm the automation actually wrote a fresh file (iCloud can lag a minute) and relaunch.
