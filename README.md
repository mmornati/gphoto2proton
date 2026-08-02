
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

Two workflows, depending on where you want your photos to end up — see
[Scripts / Proton Drive CLI → Overview](docs/scripts/overview.md) for a full
comparison and decision guide:

| | **Go binary (`gphoto2proton sync`)** | **Bash script (`gphoto2proton-import.sh`)** |
|---|---|---|
| **Target** | Proton Drive (My Files / gphoto2proton/) | Proton Photos timeline |
| **Albums** | Recreated via legacy Photos API | Recreated natively (photos-volume) |
| **EXIF** | Restored from takeout JSON sidecar (exiftool) | Read natively from files by the CLI |
| **RAW (NEF/CR2/ARW)** | ❌ Not handled | ✅ Converted to JPEG (`--convert-raw`) |
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
| 🔁 | **Resume safety** | ✅ SQLite state | ✅ Step‑aware progress files (`--resume`) |
| 🔒 | **Headless auth** | ✅ Proton API credentials | ✅ `pass` session reuse |
| 💻 | **Multi‑platform** | macOS, Linux, Windows | Linux |
| 🖼️ | **RAW conversion** | ❌ Not handled | ✅ `--convert-raw` + `--reprocess-recovery` |
| 🛠️ | **Fix capture dates** | ❌ | ✅ `fix-photo-date.sh` companion script |
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

## Quick Start — Bash scripts (Proton Photos)

Uploads directly to the **Proton Photos** timeline using the official
[Proton Drive CLI](https://github.com/ProtonDriveApps/sdk). Requires a Linux
server with the CLI installed and authenticated.

```bash
# Copy the scripts to your server
scp scripts/gphoto2proton-import.sh scripts/fix-photo-date.sh your-server:~/gphoto2proton/

# Authenticate the CLI once, then run against all archives in a directory
proton-drive auth login   # store: pass
TAKEOUT_DIR=/media/12tb/photos ~/gphoto2proton/gphoto2proton-import.sh
```

Includes `--resume`, `--albums-only`, `--convert-raw` (NEF/CR2/ARW → JPEG),
`--reprocess-recovery`, step-aware resume, and the companion
`fix-photo-date.sh` for correcting capture times of already-uploaded videos.

See **[docs/scripts/](docs/scripts/overview.md)** for the full documentation:

| Doc | Contents |
|---|---|
| [Overview](docs/scripts/overview.md) | Workflow comparison + decision guide |
| [Quick Start](docs/scripts/quickstart.md) | 2-minute walkthrough |
| [Import Script](docs/scripts/import.md) | All flags, env vars, pipeline, RAW/recovery, examples |
| [Fix Photo Date](docs/scripts/fix-photo-date.md) | Flags, date formats, safety, examples |

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

The bash script extracts **one archive at a time** to the work directory
(default `~/gphoto2proton/work/`, on a fast SSD). Peak usage is roughly
**2× the largest archive + a 2 GB buffer** — the preflight checks this and
aborts if there isn't enough free space.

**Upload time is the bottleneck:** for 354 GB across 9 archives it ranges from
**2 hours** (1 Gbps fiber) to **8+ hours** (100 Mbps upload); extraction,
checksums, and validation add roughly **1–2 hours total**.

The script is fully resumable — see
[Step-aware resume](docs/scripts/import.md#step-aware-resume) and the example
run output in the [Import Script reference](docs/scripts/import.md).

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
