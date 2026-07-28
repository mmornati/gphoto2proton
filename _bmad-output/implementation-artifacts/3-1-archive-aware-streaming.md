---
baseline_commit: b38c12a4d09d897a8c5a7a6c2bdc6183714e826b
---

# Story 3.1: Archive-Aware Streaming & Cross-Archive Albums

Status: review

## Story

As a user with a large Google Photos library (353 GB / 8 archives),
I want to process Takeout archives one at a time with automatic download management
and have albums that span multiple archives still be correctly recreated,
so that I don't need to download all archives at once or worry about disk space.

## Acceptance Criteria

1. **Streaming without buffering**: The `TakeoutReader` processes tar/tgz entries one-by-one without loading all `[]mediaEntry` data into memory.
2. **Single-archive flag**: `gphoto2proton sync --takeout-archive <path.tgz>` accepts a single .tgz file and processes it without requiring a pre-extracted directory.
3. **Auto-delete flag**: `gphoto2proton sync --takeout-archive <path.tgz> --delete-after` deletes the archive file after all its entries are successfully processed.
4. **Album persistence**: Album membership (album name → file filename mapping) persists in SQLite across separate tool invocations so albums spanning multiple archives are accumulated.
5. **Deferred album creation**: `gphoto2proton albums-finalize` command queries accumulated album state from SQLite and creates albums in Proton Photos for all uploaded files.
6. **Backward compatibility**: The existing `--takeout-dir` flow continues to work unchanged.
7. **EXIF integration preserved**: The EXIF processor operates on individual file streams in the new archive-mode path, same as directory-mode.
8. **State tracking preserved**: Per-file state is recorded in SQLite in both modes, and `--resume` works with archive-mode.

## Tasks / Subtasks

- [x] 1. Refactor `TakeoutReader` to streaming mode (AC: 1)
  - [x] 1.1 Replace `scanAll()` pre-buffer with streaming `Next()` that reads tar entries on demand
  - [x] 1.2 Remove `[]mediaEntry` in-memory buffer; stream file data through `io.ReadCloser` per `Next()` call
  - [x] 1.3 Keep album manifest accumulation as a side effect during streaming (album metadata is small, stays in memory)
  - [x] 1.4 Update all existing tests to work with the streaming reader semantics (`takeout_test.go`, `pipeline_test.go`)
  - [x] 1.5 Verify no regression in `AlbumManifest()` output (all album tests pass)

- [x] 2. Add archive-path CLI flags (AC: 2, 3, 6)
  - [x] 2.1 Add `--takeout-archive` flag to `sync` command in `root.go`
  - [x] 2.2 Add `--delete-after` boolean flag to `sync` command
  - [x] 2.3 Validate mutual exclusivity: `--takeout-dir` and `--takeout-archive` cannot both be set
  - [x] 2.4 Wire archive path into pipeline composition: create `takeout.NewStreamReader(path)` for the single `.tgz`
  - [x] 2.5 Wire delete-after logic: after successful pipeline run, `os.Remove(archivePath)`
  - [x] 2.6 Update `root_test.go` for new flag parsing

- [x] 3. Add album membership persistence to SQLite (AC: 4)
  - [x] 3.1 Add `AlbumMembership` struct and `RecordAlbumMembership(albumName, fileName string)` to `StateTracker` port
  - [x] 3.2 Create `album_members` table in SQLite: `(album_name TEXT, file_name TEXT, session_id TEXT, PRIMARY KEY (album_name, file_name, session_id))`
  - [x] 3.3 Implement `RecordAlbumMembership` on `SQLiteTracker`
  - [x] 3.4 Implement `AccumulatedAlbums(ctx) []domain.Album` that reads from `album_members` across all sessions
  - [x] 3.5 Wire album membership recording into pipeline: when processing each file's sidecar, call `RecordAlbumMembership` for each album it belongs to
  - [x] 3.6 Add tests for new SQLite methods in `state_test.go`

- [x] 4. Add `albums-finalize` command (AC: 5)
  - [x] 4.1 Create `albumsFinalize` cobra command in `root.go`
  - [x] 4.2 Command reads accumulated albums from SQLite via `AccumulatedAlbums()`
  - [x] 4.3 For each album, maps filenames to Proton file IDs and calls `CreateAlbum`
  - [x] 4.4 Record each created album state via `RecordAlbum`
  - [x] 4.5 Add CLI tests for the new command

- [x] 5. Verify existing flows (AC: 6, 7, 8)
  - [x] 5.1 Run full test suite: `go test ./...` (125 passed)
  - [x] 5.2 Run `go vet ./...` and `golangci-lint run ./...`
  - [x] 5.3 Verify `--takeout-dir` pipeline still works via pipeline tests

## Dev Notes

### Architecture constraints (from ARCHITECTURE-SPINE.md)

- **AD-2 (Hexagonal)**: Domain/port interfaces must not leak archive vs directory concerns. The `TakeoutReader` port already abstracts this — both modes produce `Next()` / `AlbumManifest()`.
- **AD-8 (Dependency Direction)**: No adapter imports another adapter. The SQLite adapter (`internal/state/`) stays independent of the takeout reader adapter (`internal/takeout/`).
- **AD-9 (State Machine)**: New `album_members` table follows the existing state machine pattern. Album membership recording is best-effort — log warnings, don't fail the pipeline.
- **AD-10 (Album Recreation)**: The pipeline still owns album→fileID accumulation. The new persistence layer just makes it survive between runs. The `albums-finalize` command reuses the same `ProtonUploader.CreateAlbum` and `translateFileIDs` logic.

### Files to touch

| File | Change |
|---|---|
| `internal/takeout/stream.go` | Refactor `scanAll()` → streaming `Next()`; keep album accumulation as side effect |
| `internal/takeout/takeout_test.go` | Update tests for streaming semanticexits |
| `internal/port/state.go` | Add `RecordAlbumMembership`, `AccumulatedAlbums` to `StateTracker` |
| `internal/state/sqlite.go` | Add `album_members` table, implement new methods |
| `internal/state/state_test.go` | Add tests for album membership persistence |
| `cmd/gphoto2proton/root.go` | Add `--takeout-archive`, `--delete-after` flags; add `albums-finalize` command |
| `cmd/gphoto2proton/root_test.go` | Test new flag parsing |
| `cmd/gphoto2proton/pipeline.go` | Wire album membership recording into `processMedia` |
| `cmd/gphoto2proton/pipeline_test.go` | Test archive-mode pipeline with streaming reader |
| `docs/commands.md` | Document new flags and `albums-finalize` command |

### Testing strategy

- **Streaming reader**: Existing tar fixtures still work — stream verification uses `io.ReadAll` on the `io.ReadCloser` returned by `Next()`.
- **Album persistence**: In-memory SQLite for unit tests of new `StateTracker` methods.
- **Pipeline**: Mock `TakeoutReader` and `StateTracker` to verify album membership recording is called per-file.
- **CLI flags**: Cobra test runner for `--takeout-archive` / `--delete-after` / mutual exclusivity.
- **Regression**: All existing 113 tests must pass before and after.

### Streaming reader refactoring details

Current `Reader` architecture:
```
NewStreamReader(paths...) → openArchive() → scanAll() → [entries buffered in memory] → Next() pops from buffer
```

Target architecture:
```
NewStreamReader(paths...) → openArchive() → [tar readers open, no scan] → Next() reads tar entry on demand
```

Key design decisions:
- `scanAll()` is deleted. Its album-accumulation logic moves into `Next()` as a side effect when sidecar JSON entries are encountered.
- `AlbumManifest()` still returns the accumulated `albumIndex` — nothing changes at the port boundary.
- The `mediaEntry.Data []byte` buffer is eliminated. `Next()` returns an `io.ReadCloser` that reads directly from the tar stream.
- After all entries from the current tar reader are exhausted (`io.EOF`), `Next()` advances to the next archive file.
- `expandMultiPart` stays for backward compatibility with multi-part archives.

### Album persistence design

New table in SQLite:
```sql
CREATE TABLE IF NOT EXISTS album_members (
    album_name TEXT NOT NULL,
    file_name  TEXT NOT NULL,
    session_id TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (album_name, file_name, session_id)
);
```

`AccumulatedAlbums()` query:
```sql
SELECT album_name, file_name FROM album_members
ORDER BY album_name, file_name
```

The pipeline calls `State.RecordAlbumMembership(albumName, fileName)` for each album a file belongs to during `processMedia()`.

### Usage examples

```bash
# Process one archive at a time:
gphoto2proton sync --takeout-archive takeout-001.tgz --delete-after
gphoto2proton sync --takeout-archive takeout-002.tgz --delete-after
# ... repeat for all 8 archives

# After all archives are done, create albums:
gphoto2proton albums-finalize

# Old workflow still works:
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --album-recreate

# Errors:
gphoto2proton sync --takeout-dir ~/Takeout --takeout-archive foo.tgz
# → error: --takeout-dir and --takeout-archive are mutually exclusive
```

### Library/framework requirements

- No new external dependencies. All additions use Go stdlib (`os`, `io`, `database/sql`).
- `modernc.org/sqlite` already in `go.mod` — no changes needed.
- Cobra CLI framework already in `go.mod` — no changes needed.

### References

- [Source: ARCHITECTURE-SPINE.md] AD-2, AD-8, AD-9, AD-10 for hexagonal architecture constraints
- [Source: `internal/takeout/stream.go`] Current `scanAll()` entry buffer and album accumulation logic
- [Source: `internal/port/state.go`] Current `StateTracker` interface
- [Source: `internal/state/sqlite.go`] Current SQLite schema and implementation patterns
- [Source: `cmd/gphoto2proton/pipeline.go`] Pipeline orchestration and album creation flow
- [Source: `cmd/gphoto2proton/root.go`] Current CLI flag definitions
- [Source: `internal/domain/migration.go`] State enum values

## Dev Agent Record

### Agent Model Used

deepseek-v4-flash-free

### Debug Log References

- All 125 tests passed at implementation time

### Completion Notes List

- Refactored `TakeoutReader` from buffered `scanAll()` to streaming `Next()` that reads tar entries on demand
- Removed `[]mediaEntry` in-memory buffer; each `Next()` call returns `io.ReadCloser` for a single entry
- Album manifest accumulation preserved as side effect during `Next()` stream
- Added `--takeout-archive` and `--delete-after` flags to sync command
- Added mutual exclusivity validation between `--takeout-dir` and `--takeout-archive`
- Added `RecordAlbumMembership` and `AccumulatedAlbums` to `StateTracker` port
- Created `album_members` table in SQLite with session-aware dedup
- Implemented album membership persistence and cross-session accumulation
- Wired `RecordAlbumMembership` into pipeline as post-upload step
- Added `albums-finalize` command that reads accumulated albums from SQLite, maps filenames to Proton file IDs, creates albums via `ProtonUploader.CreateAlbum`, and records state
- Added comprehensive tests: SQLite album methods, CLI flags, mutual exclusivity, cross-session accumulation

### File List

| File | Change |
|---|---|
| `internal/takeout/stream.go` | Refactored: removed `scanAll()`, `mediaEntry` buffer, `cursor`; streaming `Next()` reads tar entries on demand, accumulates albums as side effect |
| `internal/takeout/takeout_test.go` | Updated album manifest tests to call `drainNext()` before `AlbumManifest()` for streaming semantics; added `drainNext` helper |
| `internal/port/state.go` | Added `RecordAlbumMembership(albumName, fileName)` and `AccumulatedAlbums() []domain.Album` to `StateTracker` |
| `internal/state/sqlite.go` | Added `album_members` table creation; implemented `RecordAlbumMembership` and `AccumulatedAlbums`; `FileStates` supports empty sessionID for all-session query |
| `internal/state/migrations.go` | Added `album_members` table to `Up()` and `Down()` |
| `internal/state/state_test.go` | Added tests: `TestRecordAlbumMembership`, `TestRecordAlbumMembershipIdempotent`, `TestAccumulatedAlbums`, `TestAccumulatedAlbumsEmpty`, `TestAccumulatedAlbumsCrossSession` |
| `cmd/gphoto2proton/root.go` | Added `--takeout-archive`, `--delete-after` flags to sync; added `albums-finalize` command with state DB integration |
| `cmd/gphoto2proton/root_test.go` | Added tests for new flags, mutual exclusivity, albums-finalize command |
| `cmd/gphoto2proton/pipeline.go` | Added `recordAlbumMembership` step in `Run()` after manifest extraction |
| `cmd/gphoto2proton/pipeline_test.go` | Added `RecordAlbumMembership` and `AccumulatedAlbums` stubs to `fakeStateTracker` |
