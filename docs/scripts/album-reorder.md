# Album Reordering — `generate-album-order.sh` + `reorder-albums.sh`

Forces a deterministic, chronological ordering of the album grid on the Proton
Photos web UI (`https://drive.proton.me/u/1/photos/albums`).

## Why this is needed

The Proton web UI sorts the album grid by `album.lastActivityTime`
**descending** — the most recently active album is shown first. This field is
updated whenever a photo is **added to** or **removed from** an album, but is
**not** updated by renames or cover changes.

After an import, `lastActivityTime` reflects the *upload* order, not the actual
date of the albums, so the grid appears scrambled. The two scripts below make
`lastActivityTime` monotonic with each album's year so the UI shows albums
chronologically (newest first).

## How the reorder works

Because there is no API to set `lastActivityTime` directly, the reorder uses the
only write that updates it: removing and re-adding a photo from/to each album.
The album membership is unchanged — only `lastActivityTime` moves forward.

The two scripts are separated so the target order can be reviewed and manually
edited before anything is modified:

1. **`generate-album-order.sh`** produces a TSV listing every album with its
   inferred year, oldest first.
2. **`reorder-albums.sh`** consumes that TSV and "touches" each album
   (remove + re-add its cover photo) **in file order**, oldest → newest. The last
   album processed gets the most recent `lastActivityTime`, so the newest album
   appears first in the UI.

> **Important:** run `reorder-albums.sh` only **after** `fix-photo-date.sh` has
> finished. The fix script's album-restore step also bumps `lastActivityTime`;
> reordering first would be undone.

---

## Script 1: `generate-album-order.sh`

### Usage

```bash
generate-album-order.sh [options]
```

### Options

| Flag | Description |
|---|---|
| `--cache-dir DIR` | Directory with per-album JSON caches produced by `detect-album-conflicts.sh --cache-dir`. Used to infer years for albums whose name has no year, without hitting the API. |
| `--output FILE` | Write the TSV to `FILE` instead of stdout. |
| `-h, --help` | Show the script help. |

### Output format

Tab-separated, one album per line, sorted by **year ascending, then name**:

```
<year>\t<album name>\t<album uid>\t<cover photo uid>
```

### Year inference

1. A 4-digit year in the album name (leading or embedded) is used directly
   (e.g. `2025 - Août - Semaine à Rome` → `2025`).
2. Otherwise the year is inferred from the **majority captureTime** of the
   album's photos, using the `--cache-dir` cache when available, else a live
   API call. Albums whose year still cannot be determined are emitted with year
   `9999` and sorted last.

Albums with no cover photo (empty albums) are skipped — they cannot be touched.

### Example

```bash
./generate-album-order.sh --cache-dir photo-cache --output album-order.tsv
```

---

## Script 2: `reorder-albums.sh`

### Usage

```bash
reorder-albums.sh --file album-order.tsv [--dry-run] [--yes]
```

### Options

| Flag | Description |
|---|---|
| `-f, --file FILE` | TSV input (`year\tname\tuid\tcoverPhotoUid`) from `generate-album-order.sh`. Required. |
| `-n, --dry-run` | Print the order and what would be done, without changing anything. |
| `-y, --yes` | Skip the confirmation prompt. |
| `--delay SECONDS` | Sleep between albums so timestamps are distinct (default `2`). |
| `-h, --help` | Show the script help. |

### Safety

- If `remove-photo` fails, the album is skipped untouched.
- If `remove-photo` succeeds but `add-photo` fails, the album UID is reported so
  the cover photo can be restored manually.
- Albums without a cover photo (empty albums) are skipped.
- A **state file** (`$LOG_DIR/reorder-albums-<input>.done`) records completed
  album UIDs, so an interrupted run can be resumed by simply re-running the same
  command.
- `--dry-run` makes no API changes and creates no state entries.

### Example

```bash
# Preview only
./reorder-albums.sh --file album-order.tsv --dry-run

# Apply (after reviewing/editing album-order.tsv)
./reorder-albums.sh --file album-order.tsv --yes
```

---

## End-to-end workflow

```bash
# 1. (optional) build/refresh the photo cache for year inference
./detect-album-conflicts.sh --cache-dir photo-cache

# 2. Generate the ordered album list
./generate-album-order.sh --cache-dir photo-cache --output album-order.tsv

# 3. Optionally edit album-order.tsv to fix anything manually
#    (e.g. reorder lines, change a year column)

# 4. Dry-run, then apply
./reorder-albums.sh --file album-order.tsv --dry-run
./reorder-albums.sh --file album-order.tsv --yes

# 5. Verify in the web UI: albums should now be newest-first,
#    with the most recently used album at the top.
```

## Environment

| Variable | Default | Description |
|---|---|---|
| `CLI` | `proton-drive` | Proton Drive CLI binary. |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Directory for reorder logs and state files. |
| `PROTON_DRIVE_CREDENTIALS_STORE` | `pass` | Credential store for the CLI. |

## Dependencies

- `proton-drive` CLI (authenticated)
- `jq`
- bash 4+ (tested on 5.2), Linux (GNU coreutils)
