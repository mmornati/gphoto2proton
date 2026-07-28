# Quick Start

This guide walks you through your first migration.

---

## Step 1: Export from Google Takeout

1. Go to [Google Takeout](https://takeout.google.com/)
2. Deselect all products **except** Google Photos
3. Choose your delivery method (direct download is simplest)
4. Set export frequency to **Export once**
5. Choose archive type **.tgz** (default)
6. Set archive size to **50 GB** (fewer archives = less work)
7. Click **Create export**

    !!! warning
        Google may take hours or days to prepare large libraries.

8. Download all archives and extract them to a single directory:

    ```bash
    mkdir -p ~/Takeout
    cd ~/Takeout

    # For each downloaded .tgz:
    tar xzf takeout-20260101T120000Z-001.tgz
    tar xzf takeout-20260101T120000Z-002.tgz
    # ... repeat for all archives
    ```

    After extraction, you should see a directory structure like:

    ```
    ~/Takeout/
    └── Takeout/
        ├── Google Photos/
        │   ├── Albums/
        │   │   ├── Beach Vacation 2024/
        │   │   └── ...
        │   └── Photos from 2024/
        │       ├── photo1.jpg
        │       ├── photo1.jpg.json        # sidecar metadata
        │       └── ...
        └── metadata.json                 # album definitions
    ```

---

## Step 2: Run the Sync

```bash
gphoto2proton sync --takeout-dir ~/Takeout/Takeout
```

On first run, you will be prompted for your Proton credentials. These are stored
locally in `~/.gphoto2proton/` and reused on subsequent runs.

---

## Step 3: Recreate Albums (Optional)

```bash
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --album-recreate
```

This rebuilds your Google Photos albums inside Proton Photos with the correct
photo membership.

---

## Step 4: Resume if Interrupted

If the migration is interrupted (network issue, laptop sleep, etc.):

```bash
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --resume
```

The tool skips already-uploaded files and retries failed ones, picking up
exactly where it left off.

---

## Full Example Session

```bash
# Install
brew install exiftool
brew tap mmornati/gphoto2proton https://github.com/mmornati/gphoto2proton
brew install gphoto2proton

# Extract Takeout archives
cd ~/Downloads
for f in takeout-*.tgz; do
  tar xzf "$f" -C ~/Takeout
done

# Run migration with albums
gphoto2proton sync \
  --takeout-dir ~/Takeout/Takeout \
  --album-recreate \
  --resume
```
