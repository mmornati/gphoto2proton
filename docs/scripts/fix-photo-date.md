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
  `sha1sum`, `touch`, `find`, `awk`.

---

## Usage

```bash
fix-photo-date.sh --file fixes.tsv [--dry-run] [--yes]
```

## Flags

| Flag | Description |
|---|---|
| `-f, --file` | **Required.** TSV input file with two columns: `filename<TAB>date-or-timestamp`. |
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

A **TSV** file (tab-separated), two columns per line:

```
<filename><TAB><date or timestamp>
```

Example:

```
VID_20161015_163723.mp4	2016-10-15 16:37:23
IMG_0546.MOV	2010-08-12
1476540000	1420070400
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

## How it works (per photo)

For each entry in the file:

1. **Precheck** — fetches the timeline once; entries not found in the timeline
   are skipped, and entries with **multiple** photos of the same name are
   aborted as ambiguous (disambiguate manually).
2. **Find** — the photo's uid + album memberships are read from the Proton
   Photos timeline by filename.
3. **Download** — the original bytes are downloaded from Proton into a
   dedicated, artifact-free work subdir.
4. **Integrity check** — the downloaded file's sha1 must match the claimed
   digest; otherwise the script **refuses to destroy the original**.
5. **Fix mtime** — the filesystem mtime is set to the target date with
   `touch -t` (the CLI reads this as capture time for videos).
6. **Persist state** — a state file (uid, albums, sha1, target date, local
   path) is written **before** any destructive step.
7. **Trash** — `proton-drive filesystem trash /photos/<uid>`.
8. **Permanently delete** — `proton-drive filesystem delete /photos-trash/<uid>`.
9. **Re-upload** — `proton-drive photo upload -c keep-both`, up to 3 attempts
   (handles a stale dedup cache that may skip once after delete).
10. **Locate new uid** — matched by content sha1 (excluding the old uid),
    polling the timeline for ≤ 30 s.
11. **Verify capture time** — the new photo's `captureTime` must be within
    ±120 s of the target; otherwise the entry is marked partial.
12. **Restore albums** — re-adds the new uid to every original album,
    checking each `add-photo` result.

---

## Safety guarantees

- **Nothing is lost on failure.** The downloaded file and a state file
  (`uid`, `albums`, `sha1`, `target date`, local path) are kept in
  `$LOG_DIR/fix-work-<run>/` until the photo is **fully** fixed. Any failure
  leaves them in place for manual recovery.
- **Integrity before destruction.** If the downloaded bytes don't match the
  claimed sha1, the script refuses to trash the original.
- **Idempotent.** Photos already within ±120 s of the target date are skipped.
- **Interrupt-safe.** `SIGINT`/`SIGTERM` preserve downloads and state and exit
  with code 130.
- **Duplicate filenames rejected.** Duplicate entries in the TSV are skipped
  (first wins).

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
