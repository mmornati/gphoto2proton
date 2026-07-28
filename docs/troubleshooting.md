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

**Solutions:**

1. Clear cached credentials and re-authenticate:

   ```bash
   rm -rf ~/.gphoto2proton
   gphoto2proton sync --takeout-dir ~/Takeout
   ```

2. Verify your Proton credentials (username + password) are correct

3. If using 2FA, check if Proton-API-Bridge supports your auth method

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

1. Ensure you passed the `--album-recreate` flag
2. Verify that Proton Photos API is available (the tool uses a separate HTTP
   client for album operations, not the Drive SDK)
3. Check that photos were uploaded successfully first — albums can only be
   created with Proton file IDs from uploaded photos
4. Run with resume to retry failed albums:

   ```bash
   gphoto2proton sync --takeout-dir ~/Takeout --album-recreate --resume
   ```

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
  gphoto2proton sync --takeout-dir ~/Takeout --resume
  ```

- Consider running the migration overnight for large libraries

---

## Migration was interrupted — how do I resume?

**Solution:**

Run with the `--resume` flag:

```bash
gphoto2proton sync --takeout-dir ~/Takeout --resume
```

The tool reads the SQLite state database to determine which files were
successfully uploaded and which failed, then picks up from where it left off.
No files are re-uploaded unless they previously failed.

---

## "not yet implemented" message

**Symptoms:**

- Running sync shows: `sync called with ... (not yet implemented)`

**Solution:**

This is a stub message in the current version. The pipeline logic is
implemented and tested, but the CLI command wiring is still in development.
Run the tests to verify:

```bash
go test ./...
```
