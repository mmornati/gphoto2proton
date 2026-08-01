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

    !!! warning
        Google may take hours or days to prepare large libraries.

7. Click **Create export**
8. Download the archives to a folder. **Do not extract them** — gphoto2proton
   reads `.tgz` archives directly, entry by entry, so no extraction and no
   extra disk space are needed:

    ```bash
    mkdir -p ~/Takeout
    mv ~/Downloads/takeout-*.tgz ~/Takeout/
    ls -lh ~/Takeout/
    # takeout-20260101T120000Z-001.tgz  42G
    # takeout-20260101T120000Z-002.tgz  41G
    # ...
    ```

    !!! tip
        The archive already contains the expected structure inside
        (`Takeout/Google Photos/…`, JSON sidecars, and album metadata), so
        there is nothing left to prepare.

---

## Step 2: Run the Sync — Archive Mode (no extraction)

Process each downloaded archive with one `sync` run. On the **first** run you
must pass your Proton credentials; the authenticated session is then saved to
`~/.gphoto2proton/state/session.json` and reused automatically on later runs.

```bash
gphoto2proton sync \
  --takeout-archive ~/Takeout/takeout-20260101T120000Z-001.tgz \
  --username user@proton.me \
  --password 'your-password'
```

Add `--delete-after` to remove each archive once it has been uploaded
successfully, then repeat for every archive:

```bash
# Process one archive at a time, delete after success
gphoto2proton sync --takeout-archive ~/Takeout/takeout-001.tgz --username user@proton.me --password 'your-password' --delete-after
gphoto2proton sync --takeout-archive ~/Takeout/takeout-002.tgz --delete-after
gphoto2proton sync --takeout-archive ~/Takeout/takeout-003.tgz --delete-after
# ... repeat for all archives
```

Photo album membership is recorded in the SQLite state database for every
archive, so albums that span multiple archives are accumulated automatically.

!!! note "Alternative: directory mode"
    If you prefer (or already have) an extracted `Takeout/` directory, point
    `--takeout-dir` at it instead:

    ```bash
    gphoto2proton sync --takeout-dir ~/Takeout/Takeout --username user@proton.me --password 'your-password'
    ```

!!! tip "Already using the proton-drive CLI?"
    You can skip the username/password login entirely and reuse the session
    saved by the proton-drive CLI:

    ```bash
    pass show ch.proton.drive/drive-sdk-cli/auth-session | gphoto2proton import-session
    ```

    Afterwards run `sync`/`albums-finalize` without any credentials. See
    [Authentication](authentication.md#importing-the-proton-drive-cli-session).

---

## Step 3: Finalize Albums (Optional)

Once **all** archives have been processed, recreate your Google Photos albums
inside Proton Photos. This reads the accumulated album membership from the
state database and creates every album with the correct photos:

```bash
gphoto2proton albums-finalize
```

---

## Step 4: Resume if Interrupted

If a migration is interrupted (network issue, laptop sleep, etc.):

```bash
gphoto2proton sync --takeout-archive ~/Takeout/takeout-002.tgz --resume
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

# Download the Takeout archives into ~/Takeout (no extraction!)

# Run migration, one archive at a time
for f in ~/Takeout/takeout-*.tgz; do
  gphoto2proton sync \
    --takeout-archive "$f" \
    --username user@proton.me \
    --password 'your-password' \
    --resume \
    --delete-after
done

# Recreate albums across all archives
gphoto2proton albums-finalize
```

---

## Next Steps

- See [Commands](commands.md) for the full CLI reference.
- See [Authentication](authentication.md) for how login works on headless
  servers, session reuse, and 2FA support.
