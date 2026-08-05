# `detect-album-conflicts.sh` — Reference

Scans all Proton Photos albums and finds photos/videos whose `captureTime`
does **not** match the album's expected year. This typically affects **videos**
(.MP4, .MOV) whose EXIF was missing at upload time, causing `proton-drive` to
fall back to the upload timestamp instead of the original recording date.

Outputs a **TSV** file ready for `fix-photo-date.sh`, plus a human-readable
summary and (optionally) a JSON report.

- **Platform:** Linux (GNU `date`/coreutils).
- **Dependencies:** `proton-drive` CLI (authenticated), `jq`.

---

## Usage

```bash
detect-album-conflicts.sh [options]
```

## Flags

| Flag | Description |
|---|---|
| `--fix-tsv FILE` | Output a TSV ready for `fix-photo-date.sh` (filename, date) |
| `-n, --dry-run` | Read-only: scan and report, do not write fix TSV |
| `-v, --verbose` | List each conflicting file per album |
| `--summary-only` | Just show per-album conflict counts (no details) |
| `--json` | Output results as JSON (machine-readable) |
| `--cache-dir DIR` | Cache album photo JSONs in DIR for offline reuse on subsequent runs (only album list fetched live when cache is populated) |
| `--year YYYY` | Only check albums with this leading year |
| `--min-year YYYY` | Only check albums with year >= this (skip older) |
| `--max-conflict PCT` | If conflict % exceeds this, warn (default: 20) |
| `-h, --help` | Show help text |

## Environment variables

| Var | Default | Description |
|---|---|---|
| `CLI` | `proton-drive` | Path to the `proton-drive` binary |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Run logs directory |
| `PROTON_DRIVE_CREDENTIALS_STORE` | `pass` | Secret store for the `proton-drive` CLI session |

---

## How it works

For each album:

1. **Album year** — reads the first 4-digit year from the album name (leading
   or embedded). If none is found, fetches the album photos and uses the most
   common `captureTime` year (majority vote).
2. **Filter** — if `--year` or `--min-year` was given, albums not matching the
   filter are skipped (without an API call for albums with a year in the name).
3. **Fetch photos** — `proton-drive album photos -d --json` for the album.
   If `--cache-dir DIR` is given, each album's JSON is saved to `DIR/<uid>.json`.
   On subsequent runs, cache files are read instead of making API calls (saves
   **~7 minutes** on a full scan of 450 albums).
4. **Detect conflicts** — any photo whose `captureTime` doesn't start with the
   album year is flagged. Photos with null/empty captureTime are counted
   separately.
5. **Suggest fix date** — for each conflict, a default date is proposed using
   the album year + month inferred from the album name (e.g. "Août" → August,
   "28 Mai" → 28th of May), falling back to July 15th.

---

## Album year inference

Albums without a year in their name (e.g. `Trash`, `Failed Videos`,
`Halloween - 31 Ottobre in GeSI con ByteCode`) are handled by sampling the
`captureTime` of every photo in the album and taking the most frequent year.
This allows the script to still detect conflicts for these albums.

---

## Month detection from album names

The script recognizes month names in **English**, **Italian**, and **French**
in any case. A word-boundary check prevents false matches (e.g. "mai" inside
"semaine" will not trigger May).

When a day number precedes the month name (e.g. "28 Mai"), that day is used.
Otherwise the 15th of the month is used as a neutral default.

---

## Caching

With 450+ albums and 63,000+ photos, scanning all albums live takes **~7
minutes**, executing one `proton-drive album photos` API call per album.

The `--cache-dir DIR` flag caches each album's JSON response to a local file.
On subsequent runs, cache files are read instead of API calls — the scan
completes in **~5 seconds**.

### How to use

```bash
# First run: populate the cache from the API
./detect-album-conflicts.sh --cache-dir ~/photo-cache --fix-tsv fixes-all.tsv

# Subsequent runs: reuse the cache (no API calls for photo data)
./detect-album-conflicts.sh --cache-dir ~/photo-cache --year 2025 --summary-only
```

To refresh the cache (e.g. after uploading new photos), just delete the cache
directory:

```bash
rm -rf ~/photo-cache
./detect-album-conflicts.sh --cache-dir ~/photo-cache --fix-tsv fixes-all.tsv
```

The cache directory stores one JSON file per album (uid-based filename).
Total size for 450 albums: **~129 MB**.

---

## Examples

### Full scan, human output

```bash
./detect-album-conflicts.sh
```

```
[14:52:32] detect-album-conflicts: scan started, log=...
[14:52:34] found 450 albums

  [!!] 2025 - Août - Semaine à Rome   year=2025 total=297 conflicts=1 missing_capture=0 (0%)
       IMG_0715.MOV  captureTime=2026-07-29T21:56:17.000Z  → fix: 2025-08-15 12:00:00
  ...
```

### Generate fix TSV for one year

```bash
./detect-album-conflicts.sh --year 2025 --fix-tsv fixes-2025.tsv
```

Then fix with:

```bash
./fix-photo-date.sh --file fixes-2025.tsv --yes
```

### Summary-only (compact)

```bash
./detect-album-conflicts.sh --summary-only --year 2025
```

```
  2025 - Août - Semaine à Rome     year=2025 total=297 conflicts=1 missing_capture=0
  2025 - Août - Semaine à Chamonix year=2025 total=147 conflicts=6 missing_capture=0
```

### JSON machine-readable

```bash
./detect-album-conflicts.sh --json > report.json
```

```json
{
  "summary": {
    "albums_checked": 450,
    "total_photos": 34961,
    "total_conflicts": 601,
    "high_conflict_albums": ["2005 - Erasmus Parties (100%)"]
  },
  "albums": [
    {"name": "...", "year": "2025", "total": 297, "conflicts": 1, "...": ""}
  ]
}
```

### Check albums from a minimum year

```bash
./detect-album-conflicts.sh --min-year 2020 --verbose
```

---

## Typical workflow

### Local machine

```bash
# 1. Scan and generate fix TSV
./detect-album-conflicts.sh --cache-dir ~/photo-cache --fix-tsv conflicts.tsv

# 2. Review the output
less conflicts.tsv

# 3. Apply fixes (dry-run first)
./fix-photo-date.sh --file conflicts.tsv --dry-run
./fix-photo-date.sh --file conflicts.tsv --yes

# 4. Re-scan from cache to verify
./detect-album-conflicts.sh --cache-dir ~/photo-cache --summary-only
```

### Server (cache then fix)

```bash
# 1. First run: populate cache + generate fix TSV (takes ~7 min)
ssh server01
cd ~/gphoto2proton
./detect-album-conflicts.sh --cache-dir ~/gphoto2proton/photo-cache \
  --fix-tsv ~/gphoto2proton/fixes-all.tsv

# 2. Subsequent runs: instant (from cache)
./detect-album-conflicts.sh --cache-dir ~/gphoto2proton/photo-cache \
  --year 2025 --summary-only

# 3. Fix videos with wrong dates
./fix-photo-date.sh --file ~/gphoto2proton/fixes-all.tsv --yes

# 4. Refresh cache after fixing and re-check
rm -rf ~/gphoto2proton/photo-cache
./detect-album-conflicts.sh --cache-dir ~/gphoto2proton/photo-cache \
  --summary-only
```

---

## Output & logs

All diagnostic messages go to **stderr** so that `--json` and `--fix-tsv`
output is clean (pipe-friendly).

Run logs are written to `$LOG_DIR/detect-album-conflicts-*.log`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | All OK |
| 1 | Authentication failure or album list error |
| 2+ | Internal script error (may set `-euo pipefail` exit) |