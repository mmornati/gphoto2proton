# FAQ

---

### Does this tool delete my Google Photos?

No. This tool only reads from your Google Takeout archive. It never interacts
with your Google account — it simply processes the exported data. You can
safely delete Google Photos after verifying your migration.

---

### Do I need to extract the .tgz files?

**No.** gphoto2proton works directly on the `.tgz` archives you download from
Google Takeout — no extraction and no extra disk space needed.

**Recommended — archive mode:**

```bash
gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret'
gphoto2proton sync --takeout-archive takeout-002.tgz --delete-after
# ... one run per archive, then:
gphoto2proton albums-finalize
```

**Alternative — directory mode** (if you already extracted them):

```bash
for f in takeout-*.tgz; do
  tar xzf "$f" -C ~/Takeout
done
gphoto2proton sync --takeout-dir ~/Takeout/Takeout
```

---

### Can I run this on a headless / remote server? Does login need a browser?

**Yes, fully headless.** gphoto2proton does **not** use OAuth2 and never opens
a browser — there is no "authorize in your local browser" step. Login is done
directly against the Proton API with your username and password (SRP protocol)
via the Proton SDK.

Pass credentials on the first run:

```bash
gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret'
```

The session is saved to `~/.gphoto2proton/state/session.json` and reused
afterwards, so later runs (and `albums-finalize`) need no credentials. If the
account has **2FA (TOTP) enabled**, add the current code with `--twofa` on the
first login. See [Authentication](authentication.md) for details.

---

### Are my photos deleted from the source after migration?

No. The tool is read-only. It never modifies or deletes your Takeout archives
or extracted files.

---

### Does this work with Proton Free plan?

It depends on your storage quota. Proton Free offers 1 GB of storage —
sufficient for a small photo library. For large libraries, a paid Proton Drive
plan is required.

---

### Can I migrate to multiple Proton accounts?

Not in a single run. Run the tool separately for each account, each with its
own state directory:

```bash
gphoto2proton sync --takeout-archive takeout-001.tgz --username account1@proton.me --password 'secret' --state-dir ~/.gphoto2proton/account1
gphoto2proton sync --takeout-archive takeout-001.tgz --username account2@proton.me --password 'secret' --state-dir ~/.gphoto2proton/account2
```

---

### How long does a migration take?

It depends on:
- Total library size (Google reports 8 × ~44 GB for a typical 350 GB library)
- Your internet upload speed (Proton uploads are the bottleneck)
- Number of files (each file requires at least one API call)

For a large library, expect it to run overnight.

---

### What happens if my computer goes to sleep?

The upload pauses automatically. When you resume, use `--resume` to pick up
where you left off — completed files are tracked in SQLite and not re-uploaded.

---

### Can I migrate videos?

Yes. Videos in Takeout archives (.mov, .mp4) are processed and uploaded.
EXIF restoration is skipped for videos (exiftool handles images only).

---

### What about Live Photos?

Google Takeout exports Live Photos as separate .jpg + .mov pairs. The tool
uploads both files independently. Album membership is preserved for both.

---

### Is there a dry-run mode?

Not currently. To preview what would be processed, you can run with a small
test archive or check the number of files in your Takeout directory:

```bash
find ~/Takeout -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.mov' -o -iname '*.mp4' \) | wc -l
```

---

### How do I report a bug or request a feature?

Open an issue on [GitHub](https://github.com/mmornati/gphoto2proton/issues).
Include:

- Your platform (macOS/Linux, Intel/ARM)
- The tool version (`gphoto2proton version`)
- The exact command you ran
- The full error output
- Whether `exiftool` is installed
