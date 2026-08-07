# `detect-google-conflicts.sh` — Reference

Finds every photo on Proton Drive whose **capture time disagrees with the real
capture time recorded by Google Photos** for the same original file.

This is the ground-truth check that complements `detect-album-conflicts.sh`:
instead of *inferring* an expected year from an album's name, it reads Google's
own `photoTakenTime` (from the `*.supplemental-metadata.json` sidecar that a
Takeout export writes next to every original file) and compares it with what
Proton currently stores as `captureTime`. Any difference means the photo has the
wrong date on Proton.

- **Platform:** Linux (GNU `date`/coreutils).
- **Dependencies:** `proton-drive` CLI (authenticated), `jq`, `date`, `find`,
  `awk`, `sort`, `cut`.

---

## Why this check is needed

Photos imported from Google Photos often end up with a wrong capture time on
Proton:

- **Videos** have no `supplemental-metadata.json` in Takeout, so the CLI fell
  back to the extraction timestamp instead of the recording date.
- **Images** sometimes carry an EXIF date that Google had rewritten, or no
  usable EXIF at all, so Proton again falls back to the upload/extraction date.

`detect-album-conflicts.sh` approximates the correct year from the album name;
this script uses Google's **authoritative** timestamp instead, and also covers
photos whose album name does not reveal the year.

---

## Usage

```bash
detect-google-conflicts.sh --local-source DIR [--timeline FILE] [-o FILE]
```

## Flags

| Flag | Description |
|---|---|
| `-s, --local-source` | **Required.** Directory with the original Google Photos files (one folder per album). |
| `-i, --index` | The sha1 index file. Defaults to `DIR/.sha1-index.txt`. Useful when the index can't be written next to the photos (e.g. a read-only mount) or to point at a freshly rebuilt index. |
| `-t, --timeline` | A pre-fetched `proton-drive photo timeline -d --json` dump. Skips the ~1 min live fetch; useful when re-running with the same timeline. |
| `-o, --output` | Write the fix TSV to this file (default: stdout). |
| `-h, --help` | Show the script help. |

## Output

A fix TSV, one line per conflict, ready for `fix-photo-date.sh`:

```
<filename><TAB><nodeUid><TAB>YYYY-MM-DD HH:MM:SS
```

The date column is Google's real `photoTakenTime` (converted to the server's
timezone), so `fix-photo-date.sh` uses the correct date even when the album
name would have suggested something different.

---

## How it works

1. **Local map.** Every `*.supplemental-metadata.json` sidecar is read in a
   single batched `jq` pass (using `input_filename`), and joined against the
   sha1 index to yield `sha1 → (real epoch, basename)` for each local photo.
2. **Timeline.** The Proton Photos timeline is fetched (or read from
   `--timeline`) and collapsed to `sha1, uid, name, captureTime`.
3. **Compare.** Each timeline photo with a known sha1 is matched to its local
   real date (fallback: unique-filename match, which covers files whose bytes
   differ, e.g. NEF converted to JPG by Proton). If the UTC date parts
   disagree, it is a conflict.

## Building the sha1 index (important)

The index **must be built case-insensitively**, otherwise uppercase files
(`DSCN0810.JPG`, `*.MOV`, `*.HEIC`, `*.NEF`, …) are silently skipped:

```bash
find /media/12tb/photos -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' \
     -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.nef' \) \
  -exec sha1sum {} + > /media/12tb/photos/.sha1-index.txt
```

> Note: a case-*sensitive* lowercase-only index misses ~31,500 uppercase files
> (~23% of the library), so always use `-iname`.

---

## Typical workflow

```bash
# 1. Build the (case-insensitive) sha1 index — once, after extracting Takeout
find /media/12tb/photos -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' \
     -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.nef' \) \
  -exec sha1sum {} + > /media/12tb/photos/.sha1-index.txt

# 2. Detect all Google-sourced conflicts
~/gphoto2proton/detect-google-conflicts.sh \
  --local-source /media/12tb/photos --output fixes-google.tsv

#    If /media/12tb/photos is not writable by your user (read-only mount or
#    owned by another account), build the index elsewhere and pass it explicitly:
#    ~/gphoto2proton/detect-google-conflicts.sh --local-source /media/12tb/photos \
#      --index ~/gphoto2proton/.sha1-index.txt --output fixes-google.tsv

# 3. Review the TSV, then fix (using the same local source for speed + the
#    real dates, and --exif-date so images honour the corrected date too)
~/gphoto2proton/fix-photo-date.sh --file fixes-google.tsv \
  --album-cache photo-cache --local-source /media/12tb/photos \
  --exif-date --yes
```
