# `fix-photo-date.sh` — Reference

Fixes the **capture time** of already-uploaded Proton Photos that have the
wrong date. This typically happens for **videos**: videos in Google Photos
Takeout lack a `supplemental-metadata.json` sidecar, so during import the
`proton-drive` CLI falls back to the filesystem mtime (the archive extraction
timestamp) instead of the original recording date.

For images the CLI reads EXIF natively (dates are usually correct), so this
script is mainly used for videos — but it works for any photo whose capture
time is wrong.

- **Platform:** Linux (GNU `date`/coreutils).
- **Dependencies:** `proton-drive` CLI (authenticated), `jq`, `date`,
  `sha1sum`, `touch`, `find`, `awk`, `sort`, `cut`, `grep`.

---

## Usage

```bash
fix-photo-date.sh --file fixes.tsv [--album-cache DIR] [--dry-run] [--yes]
```

## Flags

| Flag | Description |
|---|---|
| `-f, --file` | **Required.** TSV input file with two or three columns: `filename<TAB>date-or-timestamp` or `filename<TAB>nodeUid<TAB>date-or-timestamp`. |
| `-a, --album-cache` | Directory with per-album JSON caches (from `detect-album-conflicts.sh --cache-dir`). Used to recover album membership when the timeline lacks it, and to disambiguate photos by uid. |
| `-n, --dry-run` | **Read-only.** Show what would be done without making any changes. |
| `-y, --yes` | Skip the confirmation prompt. |
| `-h, --help` | Show the script help. |

## Environment variables

| Var | Default | Description |
|---|---|---|
| `CLI` | `proton-drive` | Path to the `proton-drive` binary |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Run logs, plus the `fix-work-<ts>/` safety directory |
| `PROTON_DRIVE_CREDENTIALS_STORE` | `pass` | Secret store for the `proton-drive` CLI session |
| `TZ` | server's timezone | Override timezone for naive datetimes |

---

## Input format

A **TSV** file (tab-separated), with **two or three** columns per line:

```
<filename><TAB><date or timestamp>
<filename><TAB><nodeUid><TAB><date or timestamp>
```

The optional **nodeUid** column pins the entry to a specific photo. Use it when
multiple photos share the same filename — a uid-pinned entry is never rejected
as "ambiguous". `detect-album-conflicts.sh --fix-tsv` emits the three-column
format automatically.

Example:

```
VID_20161015_163723.mp4	2016-10-15 16:37:23
IMG_0546.MOV	2010-08-12
IMG_1234.MOV	PNR_VlVhf...~2Z09zS8Z-tg...	1476540000
```

### Supported date formats

| Format | Example | Notes |
|---|---|---|
| Unix epoch seconds | `1476540000` | 9–11 digits, sanity-checked (1990-01-01 … now+1d) |
| ISO datetime | `2016-10-15 16:37:23` or `2016-10-15T16:37:23` | |
| Compact datetime | `20161015 163723` | date + time separated by a space |
| Compact date | `20161015` | time defaults to `12:00:00` |
| Date only | `2016-10-15` | time defaults to `12:00:00` |

> **Timezone:** naive datetimes are interpreted in the **server's** timezone
> (the date matters more than the exact time). Override with `TZ=...` if needed.

---

## How it works

The script runs in three phases to avoid re-fetching the full Proton Photos
timeline (a ~160 MB JSON) for every entry.

### Phase A — Index & precheck

1. Fetches the timeline **once** and collapses it into a compact uid-keyed TSV
   index (`uid`, name, captureTime, sha1, albums) in a single `jq` pass.
2. **Precheck** — each entry is validated against the index in bulk:
   - uid-pinned entries are checked against the set of known uids;
   - name-based entries must match exactly one timeline photo (0 = missing,
     >1 = ambiguous → skipped, disambiguate by adding a nodeUid column).
3. If `--album-cache` is given, builds a reverse name→albums index from the
   per-album caches so album membership can be restored even when the timeline
   lacks `photo.albums` data.

### Phase B — Fix every photo

For each entry:

1. **Find** — the photo's uid, sha1, captureTime and album memberships are read
   from the prebuilt index (near-instant, no timeline scan). Name-based entries
   map through the index; uid-pinned entries go straight to their uid.
2. **Download** — the original bytes are downloaded from Proton into a
   dedicated, artifact-free work subdir.
3. **Integrity check** — the downloaded file's sha1 must match the claimed
   digest; otherwise the script **refuses to destroy the original**.
4. **Fix mtime** — the filesystem mtime is set to the target date with
   `touch -t` (the CLI reads this as capture time for videos).
5. **Persist state** — a state file (uid, albums, sha1, target date, local
   path) is written **before** any destructive step.
6. **Trash** — `proton-drive filesystem trash /photos/<uid>`.
7. **Permanently delete** — `proton-drive filesystem delete /photos-trash/<uid>`.
8. **Re-upload** — `proton-drive photo upload -c keep-both`, up to 3 attempts
   (handles a stale dedup cache that may skip once after delete).
9. The entry is recorded in a pending file and the local byte copy is freed.

### Phase C — Batch verify

After **all** uploads, the timeline is fetched **once** (polling a few times if
some new uids are not yet visible):

1. **Locate new uid** — a `sha1 → newest uid` map is built from the final
   timeline; each pending entry's new uid is found by content sha1.
2. **Verify capture time** — the new photo's `captureTime` must be within
   ±120 s of the target (timezone offset ignored if the date part matches);
   otherwise the entry is marked partial.
3. **Restore albums** — re-adds the new uid to every original album, checking
   each `add-photo` result.

> **Note on EXIF:** Proton derives `captureTime` from embedded EXIF for photos
> that have it. Images with a valid EXIF date keep their EXIF date regardless
> of the mtime fix — only videos (no EXIF) and photos without usable EXIF
> respond to the mtime change. Such images are marked **partial**, matching the
> behaviour of the older per-photo implementation.

---

## Safety guarantees

- **Nothing is lost on failure.** A state file (`uid`, `albums`, `sha1`,
  `target date`) is written before any destructive step and kept in
  `$LOG_DIR/fix-work-<run>/` until the photo is **fully** verified and its
  albums restored. Any failure leaves it in place for manual recovery. The
  downloaded byte copy is removed only after a successful re-upload (it's
  safely on Proton again).
- **Integrity before destruction.** If the downloaded bytes don't match the
  claimed sha1, the script refuses to trash the original.
- **Idempotent.** Photos already within ±120 s of the target date are skipped.
- **Interrupt-safe.** `SIGINT`/`SIGTERM` preserve state files and exit with
  code 130. If interrupted between Phase B and Phase C, uploaded photos keep
  their state files so a re-run can complete the verification and album
  restore.
- **Duplicate filenames rejected.** Duplicate entries in the TSV are skipped
  (first wins); non-uid-pinned duplicate names in the timeline are skipped as
  ambiguous — pin them with a nodeUid column.

---

## Examples

### Basic fix — dry run first

```bash
# Create the TSV
echo -e "VID_20161015_163723.mp4\t2016-10-15 16:37:23" > fixes.tsv
echo -e "IMG_0546.MOV\t2010-08-12" >> fixes.tsv

# See what would be done (no changes)
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --dry-run

# Execute (with confirmation prompt)
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv

# Execute (skip the prompt)
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --yes
```

### Batch from `detect-album-conflicts.sh` (with album restore)

```bash
# 1. Detect conflicts across all albums (also builds photo-cache/ for later)
~/gphoto2proton/detect-album-conflicts.sh --cache-dir photo-cache \
  --fix-tsv fixes-all.tsv

# 2. Fix everything; --album-cache restores album membership afterwards
~/gphoto2proton/fix-photo-date.sh --file fixes-all.tsv \
  --album-cache photo-cache --yes
```

The three-column TSV produced by `detect-album-conflicts.sh` pins each entry
to its exact uid, so duplicate filenames are fixed unambiguously.

### Batch of entries in different formats

```bash
cat > fixes.tsv <<'EOF'
VID_20161015_163723.mp4	2016-10-15 16:37:23
IMG_0546.MOV	2010-08-12
IMG_1234.MOV	1476540000
VID_20150101_000000.mp4	20150101
EOF

~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --dry-run
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --yes
```

### With a non-default CLI or timezone

```bash
CLI=/opt/bin/proton-drive \
TZ=Europe/Rome \
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --yes
```

### Full example session

```bash
# 1. Find videos with wrong dates (e.g. 2026-07-29 = extraction date)
proton-drive photo timeline -d --json | jq -r '.[] |
  select(.photo.captureTime | startswith("2026-07-29")) |
  [.name.value, .photo.captureTime] | @tsv'

# 2. Build the fix list with the correct dates (manual / from another source)
echo -e "VID_20161015_163723.mp4\t2016-10-15 16:37:23" > fixes.tsv

# 3. Dry-run, then execute
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --dry-run
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --yes

# 4. Check the log
ls -t ~/gphoto2proton/logs/fix-photo-date-*.log
```

---

## Output & logs

All operations are logged to `~/gphoto2proton/logs/fix-photo-date-*.log`.
Per-photo artifacts during a run live in `$LOG_DIR/fix-work-<ts>/` and are
removed when every entry is fully fixed.

Final summary per run:

```
==== done: 14 fixed, 0 partial, 0 failed ====
```

- `fixed` — fully repaired (date corrected + albums restored)
- `partial` — photo re-uploaded but something still wrong (e.g. capture time
  verification failed, or an album add failed) — work files kept
- `failed` — could not be fixed — work files kept, script exits non-zero
