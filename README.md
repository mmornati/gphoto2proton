
<p align="center">
  <img src="https://img.shields.io/badge/go-1.26.5-blue?style=flat-square" alt="Go 1.26.5"/>
  <img src="https://img.shields.io/badge/tests-126_passing-brightgreen?style=flat-square" alt="126 tests passing"/>
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License"/>
  <img src="https://img.shields.io/badge/status-active_development-yellow?style=flat-square" alt="Active Development"/>
</p>

# gphoto2proton

**Two approaches to import Google Photos Takeout into Proton — choose your target.**

```
                          ┌──────────────────────┐
    Google Takeout .tgz ─▶│  gphoto2proton sync   │──▶ Proton Drive (My Files)
      (9 archives)        │  streaming · EXIF ·   │    + legacy Photos albums
                          │  albums · resume-safe │
                          └──────────────────────┘

                          ┌──────────────────────────┐
    Google Takeout .tgz ─▶│ gphoto2proton-import.sh  │──▶ Proton Photos timeline
      (9 archives)        │  bash · proton-drive CLI │    + native album creation
                          │  extract · upload ·      │
                          │  validate · cleanup       │
                          └──────────────────────────┘
```

Two workflows, depending on where you want your photos to end up:

| | **Go binary (`gphoto2proton sync`)** | **Bash script (`gphoto2proton-import.sh`)** |
|---|---|---|
| **Target** | Proton Drive (My Files / gphoto2proton/) | Proton Photos timeline |
| **Albums** | Recreated via legacy Photos API | Recreated natively (photos-volume) |
| **EXIF** | Restored from takeout JSON sidecar (exiftool) | Read natively from files by the CLI |
| **Disk** | Streaming — no extraction | Extracts one archive at a time (≈ 2× archive size) |
| **Platform** | macOS, Linux, Windows | Linux (where `proton-drive` CLI runs) |
| **Auth** | Proton API (password / 2FA or session import) | `proton-drive auth login` session in `pass` |

---

## Features

| | Feature | Go binary | Bash script |
|---|---|---|---|
| ⚡ | **No disk extraction** | ✅ Streaming from `.tgz` | ❌ Extracts one archive at a time |
| 📸 | **EXIF metadata** | ✅ Restored via `exiftool` | ✅ Read natively by CLI |
| 🖼️ | **Proton Photos albums** | ✅ Legacy API | ✅ Native photos‑volume |
| 🔁 | **Resume safety** | ✅ SQLite state | ✅ Done‑markers + idempotent steps |
| 🔒 | **Headless auth** | ✅ Proton API credentials | ✅ `pass` session reuse |
| 💻 | **Multi‑platform** | macOS, Linux, Windows | Linux |
---

## Quick Start

### Homebrew (macOS / Linux)

```bash
brew tap mmornati/gphoto2proton https://github.com/mmornati/gphoto2proton
brew install gphoto2proton exiftool
gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret'
```

### From source

```bash
# Prerequisites
brew install exiftool          # EXIF restoration (system dependency)

# Build
git clone https://github.com/mmornati/gphoto2proton.git
cd gphoto2proton
go build -o gphoto2proton ./cmd/gphoto2proton

# Run — process .tgz archives directly (no extraction needed)
./gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret'

# Directory mode (if already extracted)
./gphoto2proton sync --takeout-dir ~/Takeout/Takeout

# Process each archive, delete after success, then recreate albums
./gphoto2proton sync --takeout-archive takeout-001.tgz --delete-after
./gphoto2proton sync --takeout-archive takeout-002.tgz
# ... all archives ...
./gphoto2proton albums-finalize

# Resume an interrupted migration
./gphoto2proton sync --takeout-archive takeout-001.tgz --resume
```

Credentials are only needed on the first run — the session is saved to
`~/.gphoto2proton/state/session.json` and reused afterwards. See
[docs/authentication.md](docs/authentication.md) for headless-server details.

Already logged into the **proton-drive CLI**? Reuse that session — no password
needed:

```bash
pass show ch.proton.drive/drive-sdk-cli/auth-session | gphoto2proton import-session
gphoto2proton sync --takeout-archive takeout-001.tgz
```

### Download pre-built binary

Grab the latest release for your platform from the
[Releases page](https://github.com/mmornati/gphoto2proton/releases) — no Go
toolchain required.

---

## Quick Start — Bash import script (Proton Photos)

Uploads directly to the **Proton Photos** timeline using the official
[Proton Drive CLI](https://github.com/ProtonDriveApps/sdk). Requires a Linux
server with the CLI installed and authenticated.

### Prerequisites

- [`proton-drive`](https://github.com/ProtonDriveApps/sdk) CLI binary installed
- Authenticated session stored in `pass` (`proton-drive auth login` once)
- `bash`, `jq`, `sha1sum`, `tar`, `flock` (standard on Linux)

### Setup

```bash
# Copy the script to your server
scp scripts/gphoto2proton-import.sh your-server:~/gphoto2proton/

# Run against all archives in a directory
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh
```

### Flags

| Flag | Description |
|---|---|
| `--check` | Read-only: verify auth, list pending / done archives |
| `--force` | Reprocess archives already marked as done |
| `--keep-work` | Keep extracted files after success (for debugging) |
| `--resume` | Skip upload/verify if artifacts from a previous run exist |
| `--albums-only` | Only recreate albums for already-uploaded photos |
| `--convert-raw` | Convert unsupported RAW formats (NEF/CR2/ARW) to JPEG before upload |
| `--reprocess-recovery` | Re-process files recorded in `recovery.tsv` (implies `--convert-raw`) |
| `--archive NAME` | Process only a single archive (name or path) |

### RAW (NEF/CR2/ARW) support

The `proton-drive` CLI **cannot ingest camera RAW formats** into Proton Photos:
RAW files are silently skipped on upload and end up listed in
`$STATE_DIR/recovery.tsv` as `missing_from_timeline` (non-fatal, since
[#23](https://github.com/mmornati/gphoto2proton/pull/23)).

To import them anyway, pass `--convert-raw`. The script detects the best
available converter and turns each RAW file into a JPEG *before* the manifest
is built, so it flows through upload/albums like any other photo:

| Converter | Detection | Notes |
|---|---|---|
| `darktable-cli` | `command -v darktable-cli` | Best quality, writes JPEG directly, preserves EXIF |
| `dcraw` + `convert` | `command -v dcraw && command -v convert` | Fallback; embeds EXIF via `exiftool` if present |

Every conversion is logged (original relpath → converted relpath, sizes and
SHA1s) to `$STATE_DIR/raw-conversions.tsv`. The original RAW file in the
`.tgz` archive is always kept.

### Recovering files already in `recovery.tsv`

If you already ran an import **without** `--convert-raw`, the RAW files are
sitting in `recovery.tsv` and were never uploaded. Recover them with:

```bash
# Recover ALL archives referenced in recovery.tsv
./scripts/gphoto2proton-import.sh --reprocess-recovery

# Recover a single archive
./scripts/gphoto2proton-import.sh --reprocess-recovery --archive takeout-20260729T191210Z-1-001.tgz
```

`--reprocess-recovery` re-extracts the affected archives, converts the recorded
RAW files to JPEG, uploads only those files (already-uploaded photos are not
re-hashed or re-transferred), re-fetches the timeline, adds the new photos to
their albums, and clears the resolved entries from `recovery.tsv`. Entries that
still fail — or RAW files the converter could not process — are preserved.

### What happens per archive

1. **Extract** — `tar xzf` into the work directory (SSD)
2. **Manifest** — `sha1sum` every media file (jpg, png, heic, mov, …)
3. **Upload** — `proton-drive photo upload -c skip` (deduplicates by content)
4. **Verify** — re-run upload (should transfer 0) + check every sha1 is in the Proton timeline
5. **Albums** — create missing albums, add photos by sha1 match (chunked in batches of 200)
6. **Validate** — confirm every album member is present on the server
7. **Cleanup** — on success: remove extracted files, mark archive done. On failure: keep files for debugging

### Environment variables

| Var | Default | Description |
|---|---|---|
| `TAKEOUT_DIR` | `$HOME/gphoto2proton/takeout` | Directory containing `.tgz` archives |
| `WORK_DIR` | `$HOME/gphoto2proton/work` | Temporary extraction directory (fast SSD recommended) |
| `LOG_DIR` | `$HOME/gphoto2proton/logs` | Run logs and per-archive artifacts |
| `STATE_DIR` | `$HOME/gphoto2proton/state` | Done-markers and lock file |
| `PROTON_DRIVE_CREDENTIALS_STORE` | `pass` | Secret store for the `proton-drive` CLI session |
| `CHUNK_SIZE` | `200` | Photos per album `add-photo` batch |
| `CLI` | `proton-drive` | Path to the `proton-drive` binary |

## How It Works

```
                    ┌──────────────────────────────┐
 Google Takeout     │   1. STREAMING READER        │
    .tgz/.tar.gz   │   tar-fs + zlib gunzip       │
    8 × ~44GB      │   entry classifier           │
                    │   JSON sidecar parser        │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │   2. EXIF PROCESSOR           │
                    │   exiftool subprocess         │
                    │   DateTimeOriginal ← JSON ts  │
                    │   GPS ← JSON location         │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │   3. UPLOAD ENGINE            │
                    │   Proton-API-Bridge SDK       │
                    │   streaming upload to Drive   │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │   4. ALBUM CREATOR            │
                    │   Proton Photos HTTP API      │
                    │   maps file IDs → albums      │
                    └──────────┬───────────────────┘
                               │
                    ┌──────────▼───────────────────┐
                    │   5. STATE TRACKER            │
                    │   SQLite (pure Go, no CGo)   │
                    │   per-file state → safe resume│
                    └──────────────────────────────┘
```

Every step streams data — no temp files, no disk doubling, no waiting for extraction.

---

## Architecture

Built with **hexagonal (ports & adapters)** architecture:

```
cmd/gphoto2proton/          ─ CLI (Cobra)
internal/
├── domain/                 ─ Core types (Media, Album, State)
├── port/                   ─ Interfaces (TakeoutReader, ExifProcessor, …)
├── takeout/                ─ Google Takeout streaming adapter
├── exif/                   ─ EXIF restoration via exiftool
├── proton/                 ─ Proton Drive upload + Photos album adapter
└── state/                  ─ SQLite state persistence
```

Each adapter implements a clean `port` interface, making the pipeline testable
with mocks and straightforward to extend.

---

## Commands

```
gphoto2proton sync             Run the migration pipeline (archive or directory)
gphoto2proton albums-finalize  Create accumulated albums in Proton Photos
gphoto2proton import-session   Reuse a session from the proton-drive CLI (no password)
gphoto2proton version          Print version
```

### sync flags

| Flag | Default | Description |
|---|---|---|
| `--takeout-archive` | — | Path to a single Takeout `.tgz` archive **(one of the two required)** |
| `--takeout-dir` | — | Path to an extracted Takeout directory **(one of the two required)** |
| `--delete-after` | `false` | Delete the archive after successful processing |
| `--username` | — | Proton username (email) — required on first login |
| `--password` | — | Proton password — required on first login |
| `--twofa` | — | Proton TOTP 2FA code — only if the account has 2FA (first login only) |
| `--resume` | `false` | Skip completed files, retry failed ones |
| `--state-dir` | `~/.gphoto2proton/state` | SQLite state + saved session location |

---

## Disk space & execution — bash script

### Archives (your setup)

| Archive | Size |
|---|---|
| `takeout-20260729T191209Z-001.tgz` | 1.1 MB (metadata only) |
| `takeout-20260729T191210Z-1-001.tgz` | 50.0 GB |
| `takeout-20260729T191210Z-1-002.tgz` | 50.0 GB |
| `takeout-20260729T191210Z-1-003.tgz` | 50.0 GB |
| `takeout-20260729T191210Z-1-004.tgz` | 50.0 GB |
| `takeout-20260729T191210Z-1-005.tgz` | 50.0 GB |
| `takeout-20260729T191210Z-1-006.tgz` | 50.0 GB |
| `takeout-20260729T191210Z-1-007.tgz` | 49.9 GB |
| `takeout-20260729T191210Z-1-008.tgz` | 3.0 GB |
| **Total compressed** | **≈ 354 GB** |

Archives stay on `/media/12tb/` (12 TB HDD, 6.8 TB free).

### Peak disk usage (per archive)

The script extracts **one archive at a time** to the work directory (default
`~/gphoto2proton/work/`, on the fast NVMe SSD). Peak consumption for the
largest archive:

| Component | Size |
|---|---|
| Compressed archive (on HDD) | 50 GB |
| Extracted content on SSD | ≈ 80 GB |
| **Peak during extraction** | **≈ 130 GB on SSD** |
| After cleanup | 0 (extraction removed, archive kept) |

The SSD at `/` has 354 GB free — enough for any single archive with room to
spare.

### What to expect during execution

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

**Upload time** is the bottleneck — for 354 GB it ranges from **2 hours**
(1 Gbps fiber) to **8+ hours** (100 Mbps upload). Processing overhead
(extraction, checksums, validation) adds roughly **1–2 hours total**.

### Resume safety

The script is fully resumable. If interrupted (SSH disconnect, power loss,
error on one archive):

1. Archives already marked done are skipped.
2. The interrupted archive is retried from scratch — all steps are idempotent.
3. Run `TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh --check`
   anytime to see progress.

### Recommended run command (your setup)

```bash
screen -S import
export PROTON_DRIVE_CREDENTIALS_STORE=pass
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh
# Detach: Ctrl+A D   |   Reattach: screen -r import
```

`screen` keeps the session alive even if your SSH connection drops.

---

## Development

```bash
go build ./cmd/gphoto2proton       # Build
go test ./...                       # Run all 126 tests
go vet ./...                        # Static analysis
```

**System dependency:** `exiftool` — install via `brew install exiftool` (macOS)
or `apt install libimage-exiftool-perl` (Linux).

---

## License

MIT — see [LICENSE](LICENSE).
