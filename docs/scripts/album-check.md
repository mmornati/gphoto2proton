# `gphoto2-album-check.sh` — Album Verification Tool

Compares album membership between **Google Photos** (from Takeout metadata) and
**Proton Photos** (live via the `proton-drive` CLI). It reads the
`albums-takeout.json` files produced during import to determine the *expected*
member set, then queries the Proton Drive API for the *actual* member set, and
diffs them by SHA-1 hash.

- **Platform:** Linux (must run where import logs and `proton-drive` CLI are
  installed).
- **Language:** bash (bash 4+; tested on 5.2).

---

## Usage

```bash
gphoto2-album-check.sh [options] [album-name-filter]
```

### Options

| Flag | Description |
|---|---|
| `--missing` | Only show albums where membership is **not** aligned. |
| `--verbose` | Also list individual member files (filenames of missing/extra photos). |
| `--list-albums` | Fast overview: list all albums found on both sides (no deep check). |
| `--json` | Output results as JSON (machine-readable, includes full summary). |
| `-h, --help` | Show the script help. |

### Positional argument

An optional **album name filter** (case-insensitive substring match). When
provided, only albums whose name contains the filter text are checked.

---

## Environment

| Variable | Default | Description |
|---|---|---|
| `CLI` | `proton-drive` | Proton Drive CLI binary. |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Directory containing `run-*/` artifact dirs with `albums-takeout.json`. |
| `STATE_DIR` | `$HOME/gphoto2proton/state` | Directory with per-archive progress files. |

---

## How it works

1. **Takeout data** — scans all `logs/run-*/<archive>/albums-takeout.json` files
   and builds a map of album name → expected member SHA-1 hashes.

2. **Proton data** — calls `proton-drive album list --json` to get the list of
   Proton albums and their UIDs. For each matched album, calls
   `proton-drive album photos -d --json /albums/{uid}` to retrieve actual
   member SHA-1 hashes.

3. **Comparison** — for each album (or the filtered subset):
   - **aligned** — expected and actual SHA-1 sets match exactly
   - **mismatched** — some photos are missing on Proton (`missing`) or present
     on Proton but not in the takeout (`extra`)
   - **missing on Proton** — album found in Google Takeout but not in Proton

4. **Report** — per-album results and a summary table.

---

## Examples

```bash
# Check all albums
./gphoto2-album-check.sh

# Check only one album (substring match)
./gphoto2-album-check.sh "Mercatini"

# Only show albums with issues (fast check for large libraries)
./gphoto2-album-check.sh --missing

# Show issues with detailed file list
./gphoto2-album-check.sh --missing --verbose

# Fast overview of both sides
./gphoto2-album-check.sh --list-albums

# Machine-readable JSON output
./gphoto2-album-check.sh --json "Mercatini"
```

---

## JSON output schema

```json
{
  "summary": {
    "takeout_albums": 216,
    "proton_albums": 430,
    "ok": 210,
    "mismatched": 5,
    "missing_on_proton": 1,
    "total_missing_members": 99,
    "total_extra_members": 0
  },
  "albums": [
    {
      "name": "2008 - 13 Dicembre - Mercatini Strasburgo",
      "expected": 512,
      "actual": 413,
      "status": "mismatch",
      "missing": 99,
      "extra": 0,
      "takeout_archive": "takeout-20260729T191210Z-1-002.tgz"
    }
  ]
}
```

---

## Limitations

- **Live Proton API required:** the script calls `proton-drive album photos` for
  every album it checks. This does **not** work while the import script
  (`gphoto2proton-import.sh`) is running, because the CLI can only handle one
  operation at a time.
- **Auth:** uses the same `pass` credential store as the import script. Run
  `proton-drive auth login` if the session expires.
- **Takeout source:** only albums present in the `albums-takeout.json` files
  from prior import runs can be compared. Albums created directly in Proton
  (not from a takeout) will show as "only on Proton".
- **Photo identification:** missing photos are identified by their SHA-1 hash
  and the filename from the takeout manifest. The Google Photos API cannot be
  used for live verification (it was restricted to app-created data in 2025).