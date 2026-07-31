
<p align="center">
  <img src="https://img.shields.io/badge/go-1.26.5-blue?style=flat-square" alt="Go 1.26.5"/>
  <img src="https://img.shields.io/badge/tests-126_passing-brightgreen?style=flat-square" alt="126 tests passing"/>
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License"/>
  <img src="https://img.shields.io/badge/status-active_development-yellow?style=flat-square" alt="Active Development"/>
</p>

# gphoto2proton

**Google Photos Takeout → Proton Drive, in a single command.**

```
                         ┌──────────────────────┐
   Google Takeout .tgz ─▶│   gphoto2proton sync  │──▶ Proton Drive
     (8 × ~44GB)         │  streaming · EXIF ·   │    + Proton Photos
                         │  albums · resume-safe │    albums recreated
                         └──────────────────────┘
```

Migrate hundreds of gigabytes from Google Photos Takeout to Proton Drive
**without unpacking archives**, losing EXIF metadata, or leaving your albums
behind.

---

## Features

| | Feature | Details |
|---|---|---|
| ⚡ | **Streaming** | Works directly on the `.tgz` archives as downloaded — no extraction, no 2× disk space |
| 📸 | **EXIF Restoration** | Writes `DateTimeOriginal`, GPS coordinates, and camera metadata via `exiftool` |
| 🖼️ | **Album Recreation** | Rebuilds your Google Photos albums inside Proton Photos automatically, even across archives |
| 🔁 | **Resume Safety** | SQLite-backed state tracker — interrupt and resume without re-uploading |
| 🔒 | **Headless Auth** | Authenticates via the Proton API (no OAuth2, no browser); credentials never leave your machine |

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

### Download pre-built binary

Grab the latest release for your platform from the
[Releases page](https://github.com/mmornati/gphoto2proton/releases) — no Go
toolchain required.

---

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
