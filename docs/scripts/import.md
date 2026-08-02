# `gphoto2proton-import.sh` — Import Script Reference

Imports Google Photos Takeout archives (`.tgz`) into the **Proton Photos
timeline** using the official
[`proton-drive` CLI](https://github.com/ProtonDriveApps/sdk). Archives are
processed one at a time through a resumable pipeline. The original `.tgz`
archives are always kept.

- **Platform:** Linux (the script targets GNU `stat`/`tar`/`flock`, and runs
  where the `proton-drive` CLI is installed).
- **Language:** bash (compatible with bash 3.2+, the server stock bash).

---

## Usage

```bash
gphoto2proton-import.sh [options]
```

## Flags

| Flag | Description |
|---|---|
| `--check` | **Read-only.** Verify auth, list pending / done archives, then exit. |
| `--force` | Reprocess archives already marked as done (resets per-archive progress). |
| `--keep-work` | Keep extracted files after a successful import (for debugging). |
| `--resume` | Continue from the last completed step. Skips re-hashing, sidecar capture-date rewrites, upload/verify, and already-processed albums. The timeline is **always re-fetched fresh**. |
| `--albums-only` | Only recreate albums from already-uploaded photos. Skips upload/verify; reprocesses archives marked as done. |
| `--convert-raw` | Convert unsupported RAW formats (NEF/CR2/ARW) to JPEG **before** upload, so Proton Photos can ingest them. Uses `darktable-cli`, or `dcraw` + ImageMagick `convert`. |
| `--reprocess-recovery` | Re-process files recorded in `recovery.tsv`: re-extract the archive, convert RAW → JPEG, upload only those files, add them to albums, and clear resolved entries. **Implies `--convert-raw`.** |
| `--archive NAME` | Process only the given archive (basename or path). |
| `-h, --help` | Show the script help. |

### Flag interaction summary

| Combination | Behavior |
|---|---|
| `--resume` | Honors completed-step markers in the per-archive progress file; skips finished work. |
| `--force` (no `--resume`) | Resets the progress file → full reprocess. |
| `--albums-only` | Never honors step markers (recomputes) but still records them for later resumes. |
| `--reprocess-recovery` | Never honors step markers; always does a fresh upload/timeline fetch. |
| `--resume` + `--albums-only` | `--resume` is ignored (warning logged). |
| `--resume` + `--reprocess-recovery` | Recovery always does a fresh upload/timeline fetch (`--resume` ignored). |

---

## Environment variables

| Var | Default | Description |
|---|---|---|
| `TAKEOUT_DIR` | `$HOME/gphoto2proton/takeout` | Directory containing `.tgz` archives |
| `WORK_DIR` | `$HOME/gphoto2proton/work` | Temporary extraction directory (fast SSD recommended) |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Run logs and per-archive artifacts |
| `STATE_DIR` | `$HOME/gphoto2proton/state` | Done-markers, lock file, progress files, `recovery.tsv` |
| `PROTON_DRIVE_CREDENTIALS_STORE` | `pass` | Secret store for the `proton-drive` CLI session |
| `CHUNK_SIZE` | `200` | Photos per album `add-photo` batch |
| `CLI` | `proton-drive` | Path to the `proton-drive` binary |

---

## Pipeline (per archive)

```
extract → strip junk → apply sidecar dates → [convert RAW → JPEG]
→ manifest (sha1) → upload (dedup) → verify → fetch timeline
→ validate media → discover albums → recreate albums → validate albums
→ summary + cleanup
```

### 1. Extract
`tar xzf` into `$WORK_DIR/<archive>/`. macOS metadata junk (`._*`,
`.DS_Store`) is stripped right after extraction.

### 2. Apply sidecar capture dates
Reads `photoTakenTime.timestamp` from each file's
`<file>.<ext>.supplemental-metadata.json` sidecar and sets the filesystem mtime
via `touch -t`. Images get correct dates from EXIF natively; **videos** fall
back to filesystem mtime, so this is what fixes their capture date at upload.

### 3. RAW conversion (`--convert-raw`)
See [RAW (NEF/CR2/ARW) support](#raw-nefcr2arw-support).

### 4. Manifest
Recursive `sha1sum` of every media file (jpg/png/heic/mov/mp4/...). Produces
`manifest.json` in the per-archive artifact dir. Content-addressed, so a
previous run's manifest is reused on resume.

### 5. Upload
`proton-drive photo upload -c skip` of the whole Google Photos tree. The CLI
flattens folders and deduplicates by name+content, so album copies of the same
photo are skipped automatically.

### 6. Verify
Re-runs upload (expect **0 transferred**) and confirms every sha1 is present in
the Proton timeline.

### 7. Timeline index
`proton-drive photo timeline -d` → maps **sha1 → uid** and **name → uid**.
Album membership is resolved by content hash, not filename.

### 8. Validate media (non-fatal)
Every manifest sha1 must be found in the timeline. Missing files are recorded
in `$STATE_DIR/recovery.tsv` (`missing_from_timeline`) — the run **does not
abort**. See [Recovery reprocessing](#recovery-reprocessing).

### 9. Discover albums
See [Album discovery](#album-discovery).

### 10. Recreate albums
`album create` for missing names, `album add-photo` in batches of `CHUNK_SIZE`
(via sha1→uid). Each completed album is persisted durably (see
[Step-aware resume](#step-aware-resume)).

### 11. Validate albums (non-fatal)
Membership mismatches are logged as warnings, not failures.

### 12. Summary + cleanup
`summary.json` is written per archive (see below). On success the extraction is
removed and the archive is marked done in `$STATE_DIR/done`. On failure the
extraction is kept for debugging.

### `summary.json` fields

| Field | Meaning |
|---|---|
| `archive` | Archive basename |
| `status` | `OK` or `EMPTY` (metadata-only archive, skipped gracefully) |
| `mode` | `import` \| `resume` \| `albums-only` \| `recovery` |
| `expected_media` | Total media files in the manifest |
| `expected_unique` | Unique sha1 count |
| `uploaded_transferred` / `uploaded_skipped` / `uploaded_failed` | Upload counters |
| `media_missing` | Files missing from the timeline (count) |
| `raw_converted` | Number of RAW → JPEG conversions |
| `album_failures` | Number of albums with membership issues |
| `albums_processed` | Number of albums completed |

---

## Step-aware resume

Since [#25](https://github.com/mmornati/gphoto2proton/pull/25), `--resume` is
truly step-aware. A durable per-archive progress file
`$STATE_DIR/progress/<archive>.json` records completed steps and per-album
results (written atomically, tmp+mv):

```json
{
  "steps": {
    "junk": true, "sidecar_dates": true, "manifest": true,
    "upload_verify": true, "timeline": true, "validate_media": true
  },
  "validate_albums": { "count": 12 },
  "albums": [
    { "name": "...", "uid": "...", "expected_members": 3,
      "matched_members": 3, "added_ok": 3 }
  ]
}
```

Resume behavior per step:

| Step | `--resume` behavior |
|---|---|
| junk strip | skipped if already done |
| sidecar dates | skipped if done **or** if upload already complete (legacy runs) |
| RAW conversion | same as sidecar dates |
| manifest | reused from current artifacts, else the previous run's `manifest.json` |
| upload/verify | skipped when complete; counters reused from the previous run (still aborts if the cached upload reported failures) |
| timeline | **always re-fetched fresh** and re-indexed — prevents stale uid mappings after re-uploads |
| media validation | skipped if already done; the `recovery.tsv` record from the first pass is preserved |
| albums | per-album: completed ones skipped; each success persisted and `albums.json` regenerated incrementally |
| album validation | skipped if the album count was already validated |

> **Why always a fresh timeline?** `fix-photo-date.sh` and RAW conversion
> re-upload photos that get **new uids for the same sha1** (old ones deleted).
> Reusing a stale timeline would map sha1s to deleted uids and silently miss
> them in album/validation steps.

---

## RAW (NEF/CR2/ARW) support

Proton Photos **cannot ingest camera RAW formats**; the CLI silently skips them
on upload and they end up in `$STATE_DIR/recovery.tsv` as
`missing_from_timeline` (non-fatal since
[#23](https://github.com/mmornati/gphoto2proton/pull/23)).

Pass `--convert-raw` to convert them to JPEG **before** the manifest is built,
so they flow through upload/albums like any other photo:

```
extract → apply sidecar dates → [CONVERT RAW → JPEG] → manifest → upload → ...
```

### Converter detection

| Converter | Detection | Notes |
|---|---|---|
| `darktable-cli` | `command -v darktable-cli` | Best quality; writes JPEG directly; preserves EXIF |
| `dcraw` + `convert` | `command -v dcraw && command -v convert` | Fallback; pipes PPM; embeds EXIF via `exiftool` if present |

If **no** converter is installed the script logs a warning and falls back to
today's behavior (RAW files land in `recovery.tsv`).

### Behavior details

- **In-place replacement:** the RAW file is removed after a successful
  conversion; `manifest.json`, upload, and album discovery all see the `.jpg`.
- **Collision-safe:** if a `.jpg` with the same basename already exists (RAW +
  JPEG side-by-side), the output gets a `-converted-N` suffix instead of
  overwriting.
- **Non-fatal:** a failed conversion logs the error, keeps the RAW, and leaves
  the file for `recovery.tsv` — it never aborts the run.
- **Audit log:** every conversion is appended to `$STATE_DIR/raw-conversions.tsv`
  (`archive<TAB>converter<TAB>orig_relpath<TAB>converted_relpath<TAB>orig_size<TAB>new_size<TAB>orig_sha1<TAB>new_sha1`)
  plus the per-archive `raw-conversions.tsv` artifact. `summary.json` gains
  `raw_converted`.
- **Original preserved:** the `.tgz` archives are never modified; the RAW
  originals are always preserved there.

---

## Recovery reprocessing

### What is `recovery.tsv`?

`$STATE_DIR/recovery.tsv` is a **global** (cross-archive) log of media files
that could not be confirmed on the Proton timeline. Each row:

```
sha1<TAB>size<TAB>archive_name<TAB>relpath<TAB>reason
```

Most entries are RAW files the CLI can't ingest (`missing_from_timeline`). It
is the durable input for `--reprocess-recovery`.

### Using `--reprocess-recovery`

If you already ran an import **without** `--convert-raw`, the RAW files are
sitting in `recovery.tsv` and were never uploaded. Recover them:

```bash
# Recover ALL archives referenced in recovery.tsv
./scripts/gphoto2proton-import.sh --reprocess-recovery

# Recover a single archive
./scripts/gphoto2proton-import.sh --reprocess-recovery --archive takeout-20260729T191210Z-1-001.tgz
```

Per affected archive:

1. Reads `recovery.tsv`, groups entries by archive, filters with `--archive`.
2. Re-extracts the archive.
3. Converts **only the recorded RAW files** (filtered, not all).
4. Stages just those files into a temp dir and uploads with `-c skip` —
   already-uploaded photos are **not re-hashed or re-transferred** (the
   whole-archive re-hash is the expensive part of a `--force` re-run).
5. Re-fetches the timeline and validates the recovered files.
6. Re-runs album discovery/processing so the new JPEGs are added to albums.
7. **Reconciles** `recovery.tsv`: resolved entries are cleared; entries still
   missing (from this run's validation) and RAW files whose conversion failed
   are preserved. A missing archive in `TAKEOUT_DIR` is reported and its
   entries kept.

### Edge cases

| Case | Handling |
|---|---|
| No converter installed | `--reprocess-recovery` aborts: it **requires** `darktable-cli`, or `dcraw` + ImageMagick `convert` |
| `recovery.tsv` empty | Logs "nothing to reprocess", exits 0 |
| Archive missing from `TAKEOUT_DIR` | Reported; entries kept |
| RAW + JPEG same basename in recovery | The JPEG equivalent is already on Proton; recovery resolves to it |

---

## Album discovery

### Standard takeout (with `Albums/` folder)
Album members come from the physical files in `Albums/<name>/`, with an
`album.json` fallback for empty dirs.

### Old-format takeout (no `Albums/` folder)
Since [#25](https://github.com/mmornati/gphoto2proton/pull/25), **each
immediate subfolder of `Google Photos/` is treated as an album**, skipping junk
dirs and `Photos from *` auto-groupings. Loose files at the root stay
non-album photos (still uploaded via the manifest).

### Limits & rules
- An album with **more than 10,000 members** fails (Proton limit) — split it in
  Google Photos first.
- Albums with **zero matched members** fail — check the timeline/upload.
- Members are matched by **sha1** (content), falling back to filename.

---

## Disk space & execution expectations

The script extracts **one archive at a time** to `WORK_DIR` (default
`~/gphoto2proton/work/`, put it on a fast SSD).

| Component | Size |
|---|---|
| Compressed archive (on HDD) | 50 GB |
| Extracted content on SSD | ≈ 80 GB |
| **Peak during extraction** | **≈ 130 GB on SSD** |
| After cleanup | 0 (extraction removed, archive kept) |

Preflight checks free disk space against `largest archive × 2 + 2 GB buffer`
and aborts if there isn't enough.

**Upload time is the bottleneck:** for 354 GB it ranges from **2 hours**
(1 Gbps fiber) to **8+ hours** (100 Mbps upload). Processing overhead
(extraction, checksums, validation) adds roughly **1–2 hours total**.

### Typical run output

```
[18:32:27] authentication OK (store: pass)
[18:32:29] disk space OK: avail=354GB, need≈156GB

[18:32:29] ==== takeout-1-001 (1/8) ====
[18:32:29] extracting ...               # 3–5 min per 50 GB archive
[18:32:29] building manifest ...        # sha1sum: 5–15 min
[18:32:29] uploading ...                # network speed dependent
[18:32:29] verify upload: transferred=0 # idempotency proof
[18:32:29] fetching photos timeline ...
[18:32:29] validation: N/N found        # sha1 coverage check
[18:32:29] albums: 0 found in takeout   # album count
[18:32:29] ==== takeout-1-001: SUCCESS ====
[18:32:29] cleaning up extracted files

... archive 2 of 8 ... 3 of 8 ... 4 of 8 ...
```

---

## Complete examples

### Basic import — all archives

```bash
screen -S import
export PROTON_DRIVE_CREDENTIALS_STORE=pass
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh
# Detach: Ctrl+A D   |   Reattach: screen -r import
```

`screen` (or `tmux`) keeps the session alive if your SSH connection drops.

### Single archive

```bash
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh \
  --archive takeout-20260729T191210Z-1-001.tgz
```

### Check status (read-only)

```bash
~/gphoto2proton/gphoto2proton-import.sh --check
#   authentication OK (store: pass)
#   [done]    takeout-20260729T191210Z-1-001.tgz
#   [pending] takeout-20260729T191210Z-1-002.tgz
```

### Resume an interrupted run

```bash
~/gphoto2proton/gphoto2proton-import.sh --resume
# or for a single archive
~/gphoto2proton/gphoto2proton-import.sh --resume --archive takeout-20260729T191210Z-1-001.tgz
```

Skips junk strip / sidecar dates / manifest rebuild / upload / verify,
reuses upload counters, fetches a fresh timeline, skips validation and
already-processed albums.

### Force a full reprocess

```bash
~/gphoto2proton/gphoto2proton-import.sh --force --archive takeout-20260729T191210Z-1-001.tgz
```

Resets the progress file and reprocesses everything, even archives marked done.

### Import with RAW conversion

```bash
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh --convert-raw
```

### Recover RAW files from a previous import

```bash
# All archives with pending recovery entries
~/gphoto2proton/gphoto2proton-import.sh --reprocess-recovery

# One archive only
~/gphoto2proton/gphoto2proton-import.sh --reprocess-recovery --archive takeout-20260729T191210Z-1-001.tgz
```

### Recreate albums only (photos already uploaded)

```bash
~/gphoto2proton/gphoto2proton-import.sh --albums-only --archive takeout-20260729T191210Z-1-001.tgz
```

### Keep extracted files for debugging

```bash
~/gphoto2proton/gphoto2proton-import.sh --keep-work --archive takeout-20260729T191210Z-1-001.tgz
```

### Custom paths & chunk size

```bash
TAKEOUT_DIR=/mnt/backups/takeout \
WORK_DIR=/mnt/nvme/work \
LOG_DIR=/mnt/backups/logs \
STATE_DIR=/mnt/backups/state \
CHUNK_SIZE=500 \
~/gphoto2proton/gphoto2proton-import.sh
```

---

## Files & artifacts layout

```
$HOME/gphoto2proton/
├── takeout/                          # TAKEOUT_DIR — your .tgz archives
├── work/                             # WORK_DIR — extraction (SSD)
├── logs/                             # LOG_DIR
│   ├── import-YYYYMMDD-HHMMSS.log    # run log
│   └── run-<ts>/<archive>/           # per-archive artifacts
│       ├── manifest.json / .tsv
│       ├── upload.json / upload-verify.json
│       ├── timeline.json + timeline-index.{sha1,name}
│       ├── validation-missing.tsv
│       ├── albums-takeout.json / albums.json / album-*.json
│       ├── raw-conversions.tsv
│       └── summary.json
└── state/                            # STATE_DIR
    ├── done                          # done-markers (one archive basename per line)
    ├── import.lock                   # flock lock (prevents concurrent runs)
    ├── progress/<archive>.json       # step-aware resume state
    ├── recovery.tsv                  # global missing-media log
    └── raw-conversions.tsv           # global RAW conversion audit log
```
