# Architecture

## High-Level Pipeline

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Google Takeout (.tgz)                           │
│              8 × ~44GB archives = 353GB total library                    │
└──────────────────────┬───────────────────────────────────────────────────┘
                       │
                       ▼ (streaming, one archive at a time)
┌──────────────────────────────────────────────────────────────────────────┐
│                    1. STREAMING PROCESSOR                                │
│                                                                          │
│  ┌──────────────┐    ┌──────────────┐    ┌────────────────────────┐     │
│  │ tar-fs +     │───▶│ Entry        │───▶│ JSON Sidecar           │     │
│  │ zlib gunzip  │    │ Classifier   │    │ Parser                 │     │
│  └──────────────┘    └──────┬───────┘    └───────────┬────────────┘     │
│                             │                        │                  │
│                      media file                 metadata (ts, GPS,     │
│                      streamed to temp           album membership)      │
│                             │                        │                  │
│                             ▼                        ▼                  │
│                      ┌────────────────────────────────────┐            │
│                      │ 2. EXIF FIXER (exiftool)           │            │
│                      │ DateTimeOriginal ← JSON timestamp  │            │
│                      │ GPS coordinates ← JSON location    │            │
│                      │ FileModifyDate ← capture time      │            │
│                      └───────────────┬────────────────────┘            │
│                                      │                                │
│                                      ▼                                │
│                      ┌────────────────────────────────────┐            │
│                      │ 3. ORGANIZER + DEDUP               │            │
│                      │ MD5 hash → skip if exists          │            │
│                      │ ALL_PHOTOS/YYYY/{file}             │            │
│                      │ Track album membership             │            │
│                      └───────────────┬────────────────────┘            │
│                                      │                                │
│                                      ▼                                │
│                      ┌────────────────────────────────────┐            │
│                      │ 4. STATE TRACKER                    │            │
│                      │ Mark archive as done                │            │
│                      │ Append to albums.json               │            │
│                      │ Save dedup DB                       │            │
│                      └────────────────────────────────────┘            │
└──────────────────────────────────┬──────────────────────────────────────┘
                                   │
                                   ▼ (per archive batch)
┌──────────────────────────────────────────────────────────────────────────┐
│                    5. UPLOAD ENGINE (Phase 2+)                           │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  proton-drive filesystem upload ./temp/ALL_PHOTOS/ \        │        │
│  │    proton://Photos/ --conflict-strategy skip --json         │        │
│  └─────────────────────────────────────────────────────────────┘        │
│                                                                          │
│                             ▼                                           │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  6. CLEANUP: delete temp/ → done with archive → next        │        │
│  └─────────────────────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼ (once all archives done)
┌──────────────────────────────────────────────────────────────────────────┐
│                    7. ALBUM SYNC (Phase 3+)                              │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────┐        │
│  │  For each album in albums.json:                              │        │
│  │    client.createAlbum(name)                                  │        │
│  │    client.addPhotosToAlbum(albumUid, photoUids)              │        │
│  └─────────────────────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────────────────────┘
```

## Component Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             CLI Layer (commander 15)                              │
│                                                                                   │
│  ┌──────────────────────┐  ┌──────────────────────┐  ┌────────────────────────┐  │
│  │  gphoto2proton       │  │  gphoto2proton       │  │  gphoto2proton         │  │
│  │  prepare <tgz> <out> │  │  sync <tgz>          │  │  sync <tgz> --albums   │  │
│  └──────────┬───────────┘  └──────────┬───────────┘  └───────────┬────────────┘  │
│             │                         │                          │               │
│         Phase 1                  Phase 2                    Phase 3               │
└─────────────┼─────────────────────────┼──────────────────────────┼────────────────┘
              │                         │                          │
              ▼                         ▼                          ▼
┌─────────────────────────┐  ┌──────────────────────┐  ┌─────────────────────────┐
│   TakeoutProcessor      │  │  UploadOrchestrator  │  │   AlbumSyncer            │
│                         │  │                      │  │                          │
│  ┌───────────────────┐  │  │ ┌────────────────┐   │  │ ┌─────────────────────┐  │
│  │ ArchiveScanner    │  │  │ │ TempManager    │   │  │ │ ProtonSDKWrapper    │  │
│  │ (tar-fs + zlib)   │  │  │ └────────────────┘   │  │ └─────────────────────┘  │
│  └───────────────────┘  │  │ ┌────────────────┐   │  │ ┌─────────────────────┐  │
│  ┌───────────────────┐  │  │ │ ProtonCLI      │   │  │ │ AlbumCreator        │  │
│  │ EntryClassifier   │  │  │ │ Wrapper        │   │  │ └─────────────────────┘  │
│  └───────────────────┘  │  │ └────────────────┘   │  │ ┌─────────────────────┐  │
│  ┌───────────────────┐  │  └──────────────────────┘  │ │ PhotoLinker          │  │
│  │ SidecarParser     │  │                            │ └─────────────────────┘  │
│  └───────────────────┘  │                            └─────────────────────────┘
│  ┌───────────────────┐  │
│  │ ExifFixer         │  │  Shared across all phases:
│  │ (exiftool)        │  │
│  └───────────────────┘  │  ┌─────────────────────────────────────┐
│  ┌───────────────────┐  │  │  Logger (chalk + ora)               │
│  │ Organizer + Dedup │  │  ├─────────────────────────────────────┤
│  └───────────────────┘  │  │  StateTracker (JSON resume file)    │
│  ┌───────────────────┐  │  ├─────────────────────────────────────┤
│  │ AlbumExtractor    │  │  │  Hasher (crypto MD5)                │
│  └───────────────────┘  │  └─────────────────────────────────────┘
│  ┌───────────────────┐  │
│  │ StateTracker      │  │
│  └───────────────────┘  │
└─────────────────────────┘
```

## Module Responsibilities

### 1. CLI Layer — `src/cli.ts`
- Uses **commander 15** for argument parsing and subcommand routing
- ESM-only (commander 15 requires Node.js ≥22.12)
- Registers `prepare`, `sync` (future), and global options (`--dry-run`, `--verbose`, `--delete-source`)

### 2. ArchiveScanner — `src/takeout/scanner.ts`
- Accepts a glob pattern (`takeout-*.tgz`) or individual file paths
- Uses **tar-fs 3.1.3** with native `zlib` for streaming decompression
- Reads tar entries sequentially — never loads the full archive into memory
- Yields each entry (header + stream) to the classifier
- Handles both `.tgz` and `.tar.gz` extensions
- Supports resume: skips already-processed archives based on state file

### 3. EntryClassifier — `src/takeout/types.ts` + inline
- Inspects each tar entry path to categorize:
  - **Media file** — images (`.jpg`, `.jpeg`, `.heic`, `.png`, `.gif`, `.webp`, `.bmp`, `.tiff`, `.raw`) and videos (`.mp4`, `.mov`, `.avi`, `.mkv`, `.m4v`, `.3gp`)
  - **JSON sidecar** — `filename.jpg.json`, contains metadata for paired media
  - **Other** — `.html`, `.txt`, etc. → skipped
- Media entries are streamed to a temp file for processing
- JSON sidecars are fully read into memory (small, metadata only)

### 4. SidecarParser — `src/takeout/parser.ts`
- Parses Google's JSON sidecar format:
  ```json
  {
    "title": "photo_001.jpg",
    "photoTakenTime": {
      "timestamp": "1650000000",
      "formatted": "Apr 15, 2022, 10:30:00 AM UTC"
    },
    "geoData": {
      "latitude": 48.8566,
      "longitude": 2.3522
    },
    "geoDataExif": {
      "latitude": 48.8566,
      "longitude": 2.3522
    }
  }
  ```
- Extracts `photoTakenTime.timestamp` → used for EXIF `DateTimeOriginal`
- Extracts `geoDataExif` for GPS coordinates
- Album membership is derived from the archive path:
  - `Takeout/Google Photos/Vacation 2020/photo.jpg` → Album: "Vacation 2020"
  - `Takeout/Google Photos/Photos from 2022/photo.jpg` → No album (date folder)

### 5. ExifFixer — `src/processor/metadata.ts`
- Writes EXIF metadata using **exiftool** (external binary v13.59+)
- Commands executed:
  ```bash
  exiftool -overwrite_original \
    "-DateTimeOriginal=${unixTimestamp}" \
    "-CreateDate=${unixTimestamp}" \
    "-FileModifyDate=${unixTimestamp}" \
    "-GPSLatitude=${lat}" "-GPSLatitudeRef=${latRef}" \
    "-GPSLongitude=${lng}" "-GPSLongitudeRef=${lngRef}" \
    "${tempFilePath}"
  ```
- Falls back gracefully if exiftool is not installed (logs warning, skips EXIF fix)
- Batches files where possible for performance

### 6. Organizer + Dedup — `src/processor/organizer.ts` + `src/processor/dedup.ts`
- **Dedup**: Computes MD5 hash using `crypto.createHash('md5')`
  - Maintains a dedup database keyed by MD5 hash → destination path
  - If hash exists, the file is skipped (saves upload time)
- **Organizer**: Copies (or hardlinks) each file to `ALL_PHOTOS/{year}/{filename}`
  - Year extracted from JSON `photoTakenTime`, fallback to file modification date
  - Naming: `{original_base}_{hash_prefix}.{ext}` to avoid collisions

### 7. AlbumExtractor — `src/processor/albums.ts`
- Builds the album manifest in memory during processing
- For each media file that belongs to an album (detected from path), records:
  ```typescript
  interface AlbumEntry {
    album: string;          // "Vacation 2020"
    filename: string;       // "beach.jpg"
    originalPath: string;   // Full takeout path for reference
    captureTime: string;    // ISO timestamp
    md5: string;            // For dedup lookup after upload
  }
  ```
- Writes `albums.json` at the end of processing (append-mode for multi-archive runs)

### 8. StateTracker — `src/utils/state.ts`
- JSON state file: `~/.gphoto2proton/state.json`
  ```json
  {
    "version": 1,
    "archives": [
      { "filename": "takeout-001.tgz", "status": "done", "processed_at": "...", "file_count": 5240 }
    ],
    "current_archive": "takeout-002.tgz",
    "dedup_db": { "d41d8cd9...": "2023/photo.jpg" }
  }
  ```
- Resume-safe: if interrupted, next run picks up unprocessed archives
- SIGINT handler: completes current file → saves state → cleans temp → exits

### 9. Logger — `src/utils/logger.ts`
- `chalk ^5.6.2` for colored terminal output
- `ora ^9.4.1` for spinners during long operations
- Log levels: `info`, `warn`, `error`, `debug` (controlled by `--verbose`)

## Data Flow — Full Sync Pipeline

```
START
  │
  ├─(1) Load state file (or init new)
  │
  ├─(2) Find first unprocessed .tgz archive
  │     │
  │     ▼
  ├─(3) Validate archive exists and is readable
  │     │
  │     ▼
  ├─(4) Create temp workspace:
  │       ./.gphoto2proton/temp/ALL_PHOTOS/
  │     │
  │     ▼
  ├─(5) Open .tgz → tar-fs extract stream
  │     │
  │     ▼
  ├─(6) For each tar entry:
  │     │
  │     ├─(6a) Classify entry type
  │     │     │
  │     │     ├── media file ──▶ stream to temp/ALL_PHOTOS/~processing/
  │     │     │                    │
  │     │     │                    ▼
  │     │     │                 Wait for paired JSON (or skip if none)
  │     │     │                    │
  │     │     │                    ▼
  │     │     │                 Has dedup hash? ──yes──▶ skip file
  │     │     │                    │ no
  │     │     │                    ▼
  │     │     │                 exiftool: set DateTimeOriginal + GPS
  │     │     │                    │
  │     │     │                    ▼
  │     │     │                 Move to ALL_PHOTOS/YYYY/{filename}
  │     │     │                    │
  │     │     │                    ▼
  │     │     │                 Record dedup hash
  │     │     │                    │
  │     │     │                    ▼
  │     │     │                 Track album membership (if any)
  │     │     │
  │     │     ├── JSON sidecar ──▶ Parse metadata → cache in memory
  │     │     │                      (linked by base filename)
  │     │     │
  │     │     └── other ──▶ Skip (log if in dry-run mode)
  │     │
  │     ▼
  ├─(7) Archive fully streamed
  │     │
  │     ▼
  ├─(8) [Phase 2] Upload:
  │       proton-drive filesystem upload \
  │         temp/ALL_PHOTOS/ proton://Photos/ \
  │         --conflict-strategy skip --json
  │     │
  │     ▼
  ├─(9) Save state: mark archive as done, append album entries
  │     │
  │     ▼
  ├─(10) Clean temp workspace
  │     │
  │     ▼
  ├─(11) [Optional] Delete source .tgz (--delete-source)
  │     │
  │     ▼
  ├─(12) Any more archives? ──yes──▶ goto (2)
  │     │ no
  │     ▼
  ├─(13) Write final albums.json
  │     │
  │     ▼
  └─(14) [Phase 3] Recreate albums in Proton Photos
          (via Proton SDK or CLI — TBD)
```

## Album Manifest Format — `albums.json`

```json
{
  "version": 1,
  "generated_at": "2026-07-27T14:30:00Z",
  "source": "Google Takeout (takeout-*.tgz)",
  "total_archives": 8,
  "total_albums": 47,
  "total_photos_in_albums": 28300,
  "albums": {
    "Summer Vacation 2023": {
      "photo_count": 147,
      "cover_photo": "photo_001.jpg",
      "photos": [
        {
          "filename": "photo_001.jpg",
          "md5": "d41d8cd98f00b204e9800998ecf8427e",
          "capture_time": "2023-07-15T14:30:00Z",
          "proton_uid": null
        }
      ]
    },
    "Family": {
      "photo_count": 892,
      "cover_photo": "family_photo_2022.jpg",
      "photos": [
        {
          "filename": "family_photo_2022.jpg",
          "md5": "e99a18c428cb38d5f22e03f7c7e9c1f2",
          "capture_time": "2022-12-25T10:00:00Z",
          "proton_uid": null
        }
      ]
    }
  }
}
```

The `proton_uid` field is populated in Phase 3 after upload (maps uploaded files to their Proton UIDs for album linkage).

## State File Format — `~/.gphoto2proton/state.json`

```json
{
  "version": 1,
  "created_at": "2026-07-27T10:00:00Z",
  "input_pattern": "./takeout-*.tgz",
  "delete_source": false,
  "archives": [
    {
      "filename": "takeout-20260726T202816Z-1-001.tgz",
      "size_bytes": 44123456789,
      "status": "done",
      "processed_at": "2026-07-27T10:45:00Z",
      "file_count": 5240,
      "album_count": 12,
      "upload_status": "pending"
    },
    {
      "filename": "takeout-20260726T202816Z-1-002.tgz",
      "size_bytes": 43987654321,
      "status": "processing",
      "started_at": "2026-07-27T10:46:00Z",
      "current_file": "Takeout/Google Photos/Family/photo_042.jpg"
    }
  ],
  "dedup_db": {
    "d41d8cd98f00b204e9800998ecf8427e": "2023/vacation_beach.jpg",
    "e99a18c428cb38d5f22e03f7c7e9c1f2": "2022/christmas_family.jpg"
  },
  "summary": {
    "total_archives": 8,
    "archives_done": 1,
    "total_files_processed": 5240,
    "total_files_skipped_dedup": 0,
    "total_upload_size_bytes": 44123456789
  }
}
```

## Error Handling Strategy

| Scenario | Handling |
|----------|----------|
| **Corrupt archive** | Skip archive, log to `errors.log`, continue with next |
| **Corrupt media file** | Skip file, log to `errors.log`, continue batch |
| **Missing JSON sidecar** | Skip EXIF fix, use file date as fallback, log warning |
| **Unsupported file format** | Copy as-is (no EXIF fix), log warning |
| **exiftool unavailable** | Continue without EXIF fix, log warning per batch |
| **Upload failure** | Retry 3× with exponential backoff, then skip + log |
| **Disk full** | Pause, log critical error, save state for resume |
| **SIGINT / Ctrl+C** | Complete current file, save state, clean temp, exit cleanly |
| **Network interruption** | Retry upload with backoff, save resume checkpoint |

## Disk Usage Strategy

```
Before processing:
  Laptop:  353GB (8 × ~44GB .tgz)
  External: 0GB

During processing (one archive):
  Laptop:  44GB (.tgz) + 44GB (temp) = 88GB peak
  Laptop:  44GB (temp) only, if .tgz deleted = 44GB peak

After processing all archives:
  Laptop:  0GB (all deleted, or .tgz kept as backup)
  Proton:  353GB (organized in Photos timeline)
```

## Target Directory Structure (Temporary Workspace)

```
.gphoto2proton/
├── temp/
│   └── ALL_PHOTOS/
│       ├── 2015/
│       │   ├── photo_001.jpg
│       │   └── photo_002.heic
│       ├── 2016/
│       └── ...
├── state.json
└── albums.json
```

## The Upload Bridge (Phase 2)

The `sync` command invokes the official Proton Drive CLI:

```bash
# Upload the entire ALL_PHOTOS folder to the Photos volume
proton-drive filesystem upload \
  .gphoto2proton/temp/ALL_PHOTOS/ \
  proton://Photos/ \
  --conflict-strategy skip \
  --json
```

This places files directly into the user's Proton Photos timeline. The Proton Photos feature reads EXIF `DateTimeOriginal` for timeline indexing and date grouping.

**Requirements:**
- User must have `proton-drive` CLI installed and authenticated (`proton-drive auth login`)
- Tool checks for CLI presence before upload and provides clear install instructions
- Output is parsed from `--json` flag for UID tracking (needed for Phase 3 album linking)

## The Album Sync Bridge (Phase 3)

Two strategies:

### Strategy A — Proton Drive SDK (preferred)
Uses `@protontech/drive-sdk` at the npm package level:

```typescript
import { ProtonDrivePhotosClient } from '@protontech/drive-sdk'

const client = new ProtonDrivePhotosClient({
  httpClient: myHttpClient,
  entitiesCache: new MemoryCache(),
  cryptoCache: new MemoryCache(),
  account: userAccount,
  openPGPCryptoModule: new OpenPGPCryptoWithCryptoProxy(cryptoProxy),
  srpModule: srpModule,
  config: { baseUrl: 'drive-api.proton.me', language: 'en' }
})

// For each album in albums.json:
const album = await client.createAlbum('Summer Vacation 2023')
for (const batch of chunks(albumPhotos, 100)) {
  await client.addPhotosToAlbum(album.uid, batch.map(p => p.protonUid))
}
```

### Strategy B — Proton CLI (when available)
Uses the CLI's upcoming `proton-drive photos` subcommands (announced as roadmap):

```bash
# Example — hypothetical future CLI commands
proton-drive photos album create "Summer Vacation 2023"
proton-drive photos album add-photos <album-id> <photo-uids>
```

## Security Considerations

- **All processing is local** — no data leaves the machine until upload
- **Proton Drive CLI handles E2E encryption** — tool never accesses encryption keys
- **Temp files are cleaned** — `SIGINT` handler ensures no leftover temp data
- **State file is local** — no telemetry, no external services
- **Credentials never stored** — auth is handled by `proton-drive auth login`
- **Proton SDK** (if used) handles all crypto locally — the tool never sees plaintext keys

## Technology Choices

### Why Node.js/TypeScript?

| Reason | Detail |
|--------|--------|
| **Streaming I/O** | Native async streams are ideal for tar processing |
| **Proton SDK compatibility** | The Proton Drive SDK is TypeScript-first |
| **Cross-platform** | Single codebase for macOS, Linux, Windows |
| **Rich CLI ecosystem** | commander, chalk, ora — mature and well-maintained |
| **ESM maturity** | All key dependencies are ESM-native in 2026 |

### Why exiftool?

| Reason | Detail |
|--------|--------|
| **Accuracy** | Handles all edge cases across 100+ image/video formats |
| **Non-destructive** | Can write in-place without re-encoding |
| **GPS handling** | Proper lat/lon ref calculation and format conversion |
| **Sub-second accuracy** | Preserves fractional timestamps |
| **Availability** | Available on all platforms via package managers |

### Why tar-fs?

| Reason | Detail |
|--------|--------|
| **Streaming** | Processes one entry at a time, minimal memory |
| **Pipe-friendly** | Works directly with zlib gunzip streams |
| **Filter support** | `map`/`filter` options for entry-level decisions |
| **Lightweight** | Pure JS, no native bindings, ~50KB |

## Development Pipeline

```
src/*.ts ──▶ tsc (TypeScript 7) ──▶ dist/*.js ──▶ node dist/cli.js
                                                │
test/*.ts ──▶ vitest ───────────────────────────▶ test results
```

- `tsconfig.json`: `"module": "nodenext"`, `"target": "es2024"`, `"moduleResolution": "nodenext"`
- `package.json`: `"type": "module"`, `"bin": { "gphoto2proton": "./dist/cli.js" }`
- Formatting: built-in, no Prettier dependency
- Testing: Vitest 4.x with `node:test` runner

## Version Compatibility Matrix

| Dependency | Min Version | Notes |
|-----------|-------------|-------|
| Node.js | 22.12.0 | Required by commander 15 ESM |
| Node.js (recommended) | 24.18.0 LTS | Current LTS as of July 2026 |
| TypeScript | 7.0.2 | Native port, 10× faster |
| commander | 15.0.0 | ESM-only, requires Node ≥22.12 |
| tar-fs | 3.1.3 | Streaming tar extraction |
| chalk | ^5.6.2 | ESM-only, terminal colors |
| ora | ^9.4.1 | ESM-only, terminal spinners |
| vitest | ^4.1.10 | Vite-native test framework |
| exiftool | 13.59 | External binary |
| Proton Drive CLI | 0.6.0 | External binary (Phase 2+) |
| Proton Drive SDK | 0.13.1 | npm package (Phase 3+) |

## Future Extensibility

The modular architecture makes it straightforward to:

- **Add new output formats** — plugins for Immich, Synology Photos, etc.
- **Accept other archive formats** — `.zip` support by switching the extraction backend
- **Add diff mode** — compare Proton library with Takeout, only upload new photos
- **Add batch/parallel** — process multiple archives concurrently on multi-core systems
- **Add verification** — compare MD5 hashes between local and Proton after upload

## References

- [Google Takeout](https://takeout.google.com)
- [Proton Drive CLI](https://proton.me/support/drive-cli)
- [Proton Drive SDK](https://www.npmjs.com/package/@protontech/drive-sdk)
- [ExifTool](https://exiftool.org)
- [tar-fs](https://github.com/mafintosh/tar-fs)
- [commander.js](https://github.com/tj/commander.js)
- [TypeScript 7.0 Announcement](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/)
