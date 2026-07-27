# gphoto2proton — Google Photos to Proton Drive Migration Tool

## Overview

A cross-platform CLI tool to migrate Google Photos libraries to Proton Drive Photos on macOS/Linux. Handles the full pipeline: streaming Google Takeout processing → EXIF metadata fixing → upload to Proton Photos → album recreation.

## Motivation

On Windows, the Proton Drive desktop app has a native "Import from Google Photos" feature that auto-recreates albums during import. On macOS, Linux, and the web app, no equivalent exists. Users are left manually fixing EXIF timestamps, uploading the massive library, and recreating albums by hand — impractical for libraries of 350GB+.

**The gap:** no cross-platform tool can programmatically recreate albums in Proton Photos on macOS/Linux.

## Phases

### Phase 1 — `prepare`: Takeout Processing (MVP)

Stream `.tgz` files directly (no full extraction), fix EXIF timestamps from JSON sidecar metadata, organize photos into year-based folders, and extract album structure into a machine-readable manifest.

**Deliverable:** `gphoto2proton prepare takeout-*.tgz ./output`

### Phase 2 — `upload`: Direct Upload to Proton Photos

Orchestrate upload via the official `proton-drive` CLI. Process one `.tgz` batch → fix EXIF in temp → upload to `proton://Photos/` → delete temp → repeat.

**Deliverable:** `gphoto2proton sync takeout-*.tgz`

### Phase 3 — `sync`: Album Recreation

Create albums and link photos in Proton Photos. Uses either the Proton Drive SDK (`ProtonDrivePhotosClient.createAlbum()`) when available, or the CLI's upcoming Photos/album support.

**Deliverable:** `gphoto2proton sync takeout-*.tgz --albums`

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Streaming `.tgz`** | 353GB library split into 8 × ~44GB archives. No disk space for full extraction. |
| **One archive at a time** | Peak ~44GB temp workspace, works on laptops with limited free space. |
| **External `exiftool`** | Gold standard for EXIF. Handles all formats (HEIC, RAW, video) reliably. |
| **State/resume tracking** | JSON state file ensures interrupted runs pick up where they left off. |
| **Direct-to-Proton pipeline** | Optional external SSD path, but zero-storage path is the primary flow. |
| **ESM-only** | Latest dependencies (commander 15, chalk 5+, ora 9+) all require ESM. |

## Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Runtime | [Node.js](https://nodejs.org) | v24.18.0 LTS (min v22.12.0) |
| Language | [TypeScript](https://www.typescriptlang.org) | 7.0.2 |
| CLI framework | [commander](https://github.com/tj/commander.js) | 15.0.0 |
| Archive streaming | [tar-fs](https://github.com/mafintosh/tar-fs) | 3.1.3 |
| Decompression | `zlib` (native) | (built-in) |
| EXIF manipulation | [exiftool](https://exiftool.org) | 13.59 *(external)* |
| Terminal output | [chalk](https://github.com/chalk/chalk) | ^5.6.2 |
| Progress spinners | [ora](https://github.com/sindresorhus/ora) | ^9.4.1 |
| Testing | [Vitest](https://vitest.dev) | ^4.1.10 |
| Hashing | `crypto` (native) | (built-in) |
| File upload | [Proton Drive CLI](https://proton.me/support/drive-cli) | 0.6.0 *(external, Phase 2+)* |

## Disk Usage Profile

```
Initial state: 8 × ~44GB .tgz = 353GB on laptop

Processing (per archive):
  Input:  44GB  (.tgz being processed)
  Temp:   44GB  (extracted files being fixed and uploaded)
  Peak:   88GB  (archive + temp, before deletion option)
  Output:  0GB  (direct to Proton, no local output)

After each archive:
  Option A:  delete .tgz → free 44GB → peak stays ~44GB
  Option B:  keep .tgz    → archive count reduces by 1

Final state (Option A):
  0GB on laptop (all deleted after upload)
```

## File Structure

```
gphoto2proton/
├── package.json
├── tsconfig.json
├── src/
│   ├── cli.ts                     # Entry point (commander)
│   ├── commands/
│   │   └── prepare.ts             # `prepare` command
│   ├── takeout/
│   │   ├── scanner.ts             # Scan & index archive entries
│   │   ├── parser.ts              # Parse JSON sidecar metadata
│   │   └── types.ts               # TypeScript interfaces
│   ├── processor/
│   │   ├── archive.ts             # Streaming .tgz extraction
│   │   ├── metadata.ts            # EXIF fix via exiftool
│   │   ├── organizer.ts           # Organize into ALL_PHOTOS/YYYY/
│   │   ├── dedup.ts               # MD5 deduplication
│   │   └── albums.ts              # Build album manifest
│   └── utils/
│       ├── logger.ts              # chalk + ora logging
│       ├── hash.ts                # File hashing
│       └── state.ts               # Resume state tracking
├── test/
│   ├── takeout/                   # Scanner & parser tests
│   ├── processor/                 # Metadata & organizer tests
│   └── utils/                     # Logger & hash tests
├── plan.md                        # This file
└── architecture.md                # Architecture document
```

## Usage

```bash
# Prepare from .tgz archives (output to local disk for manual upload)
gphoto2proton prepare ./takeout-*.tgz ./organized-photos

# Prepare + upload directly to Proton (Phase 2)
gphoto2proton sync ./takeout-*.tgz

# Prepare + upload + recreate albums (Phase 3)
gphoto2proton sync ./takeout-*.tgz --albums

# Preview only — no changes
gphoto2proton prepare ./takeout-*.tgz ./output --dry-run

# Delete source .tgz after processing (free space)
gphoto2proton sync ./takeout-*.tgz --delete-source
```

## Status

Phase 1 in development. Phases 2 and 3 planned (blocked on Proton CLI Photos support, or resolved via SDK).
