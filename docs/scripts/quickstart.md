# Scripts Quick Start

Get the bash import pipeline running in a few minutes. This page assumes you
have a **Linux server** where the
[proton-drive CLI](https://github.com/ProtonDriveApps/sdk) can be installed and
your Google Photos Takeout archives are downloaded.

---

## Step 1: Install prerequisites

```bash
# proton-drive CLI (see https://github.com/ProtonDriveApps/sdk for install)
# Standard tools:
sudo apt install jq coreutils tar
# RAW support (optional — needed only for --convert-raw / --reprocess-recovery):
sudo apt install darktable-cli
```

The scripts also need `flock` (in `util-linux`, usually preinstalled) and
`sha1sum` (in `coreutils`).

## Step 2: Authenticate the proton-drive CLI

The scripts reuse the CLI's session, stored in the `pass` secret store. Log in
once:

```bash
proton-drive auth login        # store: pass (default for the scripts)
```

You can verify the session works with:

```bash
proton-drive album list
```

!!! tip
    The scripts export `PROTON_DRIVE_CREDENTIALS_STORE=pass` automatically. If
    your session lives in a different store, set the variable yourself — see
    [Environment variables](import.md#environment-variables).

## Step 3: Copy the scripts to your server

```bash
scp scripts/gphoto2proton-import.sh scripts/fix-photo-date.sh your-server:~/gphoto2proton/
```

## Step 4: Run the import

Point the script at your archive directory and run it. It processes **every
`.tgz` in `TAKEOUT_DIR`**, one at a time:

```bash
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh
```

Or target a single archive:

```bash
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh --archive takeout-20260729T191210Z-1-001.tgz
```

Use `--check` anytime to see pending / done archives without running anything:

```bash
~/gphoto2proton/gphoto2proton-import.sh --check
```

## Step 5: Handle RAW files (optional)

If your library contains camera RAW files (NEF/CR2/ARW), Proton Photos cannot
ingest them as-is — they land in `recovery.tsv`. Convert them to JPEG during
import:

```bash
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh --convert-raw
```

If you already ran an import **without** `--convert-raw`, recover the recorded
RAW files afterwards:

```bash
~/gphoto2proton/gphoto2proton-import.sh --reprocess-recovery
```

## Step 6: Fix wrong capture dates (optional)

Some videos lack a takeout sidecar, so the CLI falls back to the archive
extraction timestamp instead of the recording date. To fix already-uploaded
photos, create a TSV of `<filename><TAB><date>` and run `fix-photo-date.sh`:

```bash
echo -e "VID_20161015_163723.mp4\t2016-10-15 16:37:23" > fixes.tsv

# Dry-run first, then execute
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --dry-run
~/gphoto2proton/fix-photo-date.sh --file fixes.tsv --yes
```

---

## What happens per archive

```
extract → strip junk → apply sidecar dates → [convert RAW] → manifest (sha1)
→ upload (dedup) → verify → fetch timeline → validate media → recreate albums
→ validate albums → cleanup
```

On success the extracted files are removed and the archive is marked done.
On failure the extraction is kept for debugging, and the archive can be resumed
with `--resume` (see [Step-aware resume](import.md#step-aware-resume)).

---

## Next steps

- [Import Script Reference](import.md) — every flag and env var
- [Fix Photo Date Reference](fix-photo-date.md) — date formats and safety
- [Scripts Overview](overview.md) — choose between Go binary and bash scripts
