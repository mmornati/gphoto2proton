# Troubleshooting

---

## EXIF restoration is not working

**Symptoms:**

- Photos uploaded without DateTimeOriginal or GPS data
- Warning: `exiftool not found, EXIF processing disabled`

**Solution:**

Install `exiftool`:

```bash
# macOS
brew install exiftool

# Ubuntu/Debian
sudo apt install libimage-exiftool-perl

# Fedora
sudo dnf install perl-Image-ExifTool
```

The tool detects `exiftool` automatically on next run.

---

## Upload fails with authentication error

**Symptoms:**

- Error: `authentication failed` or `invalid credentials`
- Error: `creating uploader: ... ErrUsernameAndPasswordRequired`
- Error: `2FA code required` / `Err2FACodeRequired`

**Solutions:**

1. Clear the saved session and re-authenticate:

   ```bash
   rm -f ~/.gphoto2proton/state/session.json
   gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret'
   ```

2. Verify your Proton username (email) and password are correct. The first run
   requires both `--username` and `--password`; later runs reuse the saved
   session and do not need them.

3. If you see `2FA code required`: the account has two-factor authentication
   (TOTP) enabled, which is not supported yet. See
   [Authentication → 2FA](authentication.md#two-factor-authentication-2fa--not-yet-supported)
   for workarounds.

---

## SQLite database locked error

**Symptoms:**

- Error: `database is locked`

**Solutions:**

- Ensure only one `gphoto2proton sync` process is running at a time
- If the process was killed abruptly, delete the state database:

  ```bash
  rm -rf ~/.gphoto2proton/state
  ```

  This loses resume state — the migration will restart from scratch.

---

## Album creation is not working

**Symptoms:**

- Albums are not recreated in Proton Photos
- Warning: `album creation failed`

**Solutions:**

1. Verify that photos were uploaded successfully first — albums can only be
   created with Proton file IDs from uploaded photos
2. If you migrate several archives, make sure you have processed **all** of
   them and then run `albums-finalize` to create the accumulated albums:

   ```bash
   gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret'
   gphoto2proton sync --takeout-archive takeout-002.tgz
   # ... all archives ...
   gphoto2proton albums-finalize
   ```

3. The tool uses a separate HTTP client for album operations (the Proton
   Photos API), not the Drive SDK — a missing `session.json` or an expired
   session causes album calls to fail
4. Run with `--resume` to retry failed files before finalizing albums

---

## Memory usage is too high

**Symptoms:**

- Process is killed by OOM (out of memory)
- High memory consumption during migration

**Solutions:**

- Each file is streamed through the pipeline — memory usage depends on the
  largest file in your library
- If you have very large video files (>500 MB), consider running migration in
  batches
- Ensure you have enough swap space configured

---

## Network timeout during upload

**Symptoms:**

- Upload hangs or times out on large files
- Error: `connection timeout`

**Solutions:**

- Check your internet connection stability
- Large uploads to Proton can be slow — the tool handles timeouts gracefully
- Use the `--resume` flag to retry failed files:

  ```bash
  gphoto2proton sync --takeout-archive takeout-001.tgz --resume
  ```

- Consider running the migration overnight for large libraries

---

## Migration was interrupted — how do I resume?

**Solution:**

Run with the `--resume` flag:

```bash
gphoto2proton sync --takeout-archive takeout-001.tgz --resume
```

The tool reads the SQLite state database to determine which files were
successfully uploaded and which failed, then picks up from where it left off.
No files are re-uploaded unless they previously failed.
