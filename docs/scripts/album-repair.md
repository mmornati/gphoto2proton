# `gphoto2-album-repair.sh` — Album Repair Tool

Repairs album membership between **Google Photos** (from Takeout metadata) and
**Proton Photos**. Reads the `albums-takeout.json` files produced during import
to determine the *expected* member set, then queries Proton Photos to find
discrepancies and fixes them.

- **Platform:** Linux (must run where import logs and `proton-drive` CLI are
  installed).
- **Language:** bash (bash 4+; tested on 5.2).

---

## Usage

```bash
gphoto2-album-repair.sh [options] [album-name-filter]
```

### Options

| Flag | Description |
|---|---|
| `--dry-run` | Preview what would be done without making any changes. |
| `--verbose` | Show per-photo details (unresolvable members, missing SHA-1s). |
| `--json` | Output results as JSON (machine-readable, includes full summary). |
| `-h, --help` | Show the script help. |

### Positional argument

An optional **album name filter** (case-insensitive substring match). When
provided, only albums whose name contains the filter text are processed.

---

## Environment

| Variable | Default | Description |
|---|---|---|
| `CLI` | `proton-drive` | Proton Drive CLI binary. |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Directory containing `run-*/` artifact dirs with `albums-takeout.json`. |
| `STATE_DIR` | `$HOME/gphoto2proton/state` | Directory with per-archive progress files. |
| `CHUNK_SIZE` | `200` | Number of photos to add per API call (Proton limit). |

---

## How it works

1. **Takeout data** — scans all `logs/run-*/<archive>/albums-takeout.json` files
   and builds a map of album name → expected member SHA-1 hashes. Albums
   spanning multiple archives are merged automatically.

2. **Timeline index** — fetches the Proton photo timeline via
   `proton-drive photo timeline -d --json` and builds a SHA-1 → UID lookup
   table, matching the same strategy used by the import script.

3. **Album check** — for each expected album:
   - **OK** — all expected members are present on Proton (skipped).
   - **Missing album** — the album does not exist on Proton. Created with all
     resolved members (or reported in `--dry-run` mode).
   - **Missing members** — the album exists but some expected photos are not
     in it. Only the missing members are added.

4. **Execution** — photos are added via `proton-drive album add-photo` in
   batches of `CHUNK_SIZE`. Albums with more than 10,000 members are skipped
   (Proton limit).

---

## Examples

```bash
# Preview what would be done (no changes)
./gphoto2-album-repair.sh --dry-run

# Preview with per-album details
./gphoto2-album-repair.sh --dry-run --verbose

# Fix all albums
./gphoto2-album-repair.sh

# Fix only albums matching a filter
./gphoto2-album-repair.sh "Vacation"

# Machine-readable JSON output
./gphoto2-album-repair.sh --json
```

---

## Typical workflow

```bash
# 1. Check current state (read-only)
./gphoto2-album-check.sh --missing

# 2. Preview repairs
./gphoto2-album-repair.sh --dry-run

# 3. Apply fixes
./gphoto2-album-repair.sh

# 4. Verify alignment
./gphoto2-album-check.sh --missing
```

---

## JSON output schema

```json
{
  "summary": {
    "takeout_albums": 216,
    "proton_albums": 430,
    "processed": 216,
    "ok": 210,
    "created": 1,
    "repaired": 5,
    "errors": 0,
    "photos_added": 99,
    "dry_run": false
  },
  "albums": [
    {
      "name": "2008 - 13 Dicembre - Mercatini Strasburgo",
      "action": "repaired",
      "missing": 99,
      "resolvable": 99,
      "added": 99,
      "failed": 0
    }
  ]
}
```

### Album actions

| `action` | Meaning |
|---|---|
| `ok` | Album is fully aligned — no action needed. |
| `created` | Album was created on Proton and populated with all members. |
| `repaired` | Album existed on Proton; missing members were added. |
| `would_create` | (Dry-run only) Album would be created. |
| `would_repair` | (Dry-run only) Missing members would be added. |

---

## Limitations

- **Live Proton API required:** the script calls `proton-drive` for the photo
  timeline, album list, album photos, album creation, and adding photos. This
  does **not** work while the import script (`gphoto2proton-import.sh`) is
  running, because the CLI can only handle one operation at a time.
- **Auth:** uses the same `pass` credential store as the import script. Run
  `proton-drive auth login` if the session expires.
- **Takeout source:** only albums present in the `albums-takeout.json` files
  from prior import runs can be repaired. Albums created directly in Proton
  (not from a takeout) are ignored.
- **Member resolution:** photos are matched by SHA-1 hash from the Proton
  timeline. If a photo's SHA-1 has changed since import (e.g. re-encoded) and
  the filename also differs, it cannot be matched and will be skipped.
- **Large albums:** albums with more than 10,000 members are skipped (Proton
  API limit). These must be split manually.