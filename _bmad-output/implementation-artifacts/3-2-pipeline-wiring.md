# Story 3.2: Pipeline Wiring & Sync Command Completion

Status: ready-for-dev

## Story

As a user with a large Google Photos library,
I want `gphoto2proton sync --takeout-archive <path.tgz>` to actually process files (with EXIF restoration and albums-finalize mapping),
so that the archive-mode streaming pipeline works end-to-end and albums are correctly created.

## Acceptance Criteria

1. **Sync command is wired**: `gphoto2proton sync --takeout-archive <path.tgz>` composes `takeout.NewStreamReader(path)`, creates a `Pipeline`, and calls `Pipeline.Run()`. The current `fmt.Fprintf(..., "not yet implemented")` stub is replaced with real composition.

2. **Directory mode preserved**: `gphoto2proton sync --takeout-dir <dir>` continues to work. The directory-mode reader is also wired through the pipeline (it was also a stub).

3. **`--delete-after` deletes on success**: When `--delete-after` is set, the archive file is removed via `os.Remove()` after a successful pipeline run. On failure, the archive is NOT deleted.

4. **EXIF processor wired into pipeline**: The `Pipeline` struct gains an `ExifProcessor port.ExifProcessor` field. The `processMedia` method calls `exifProcessor.Process(ctx, rc, meta)` between `Reader.Next()` and `Uploader.Upload()`. The sidecar metadata is obtained by adding an optional `Metadata *domain.MediaMeta` field to `domain.Media` that the streaming reader populates.

5. **Filename to fileID mapping persisted**: The pipeline calls `State.RecordFull(ctx, fileID, state, fileName, fileSize, "")` instead of `State.Record()` so the `file_name` column is populated in SQLite for the `albums-finalize` command.

6. **`albums-finalize` maps correctly**: The `albums-finalize` command in `root.go` successfully looks up Takeout filenames to Proton file IDs via `FileStates("")` now that `file_name` is properly stored.

7. **`--resume` works in archive-mode**: When `--resume` is set, the pipeline checks `State.PendingFiles()` before processing and skips already-uploaded files.

8. **All existing tests pass**: `go test ./...` passes (125+ tests). `go vet ./...` and `golangci-lint run ./...` pass.

## Tasks / Subtasks

- [ ] 1. Wire sync command in root.go (AC: 1, 2, 3)
  - [ ] 1.1 Replace the "not yet implemented" fmt.Printf stub with actual pipeline composition
  - [ ] 1.2 Create `takeout.NewStreamReader(takeoutArchive)` for archive mode
  - [ ] 1.3 Create directory-mode reader for `--takeout-dir`
  - [ ] 1.4 Create `state.NewSQLiteTracker(stateDBPath)` and wire `StateTracker`
  - [ ] 1.5 Create `proton.NewUploader(...)` and wire `ProtonUploader`
  - [ ] 1.6 Create `exif.NewProcessor()` and wire `ExifProcessor`
  - [ ] 1.7 Create `Pipeline` with all ports and call `Run()`
  - [ ] 1.8 After successful `Run()`, if `--delete-after`, call `os.Remove(takeoutArchive)`
  - [ ] 1.9 Pass context from cobra command to pipeline via `cmd.Context()`
  - [ ] 1.10 Add pipeline composition tests

- [ ] 2. Add ExifProcessor to Pipeline (AC: 4)
  - [ ] 2.1 Add `ExifProcessor port.ExifProcessor` field to `Pipeline` struct
  - [ ] 2.2 In `processMedia`, call `exifProcessor.Process(ctx, rc, media.Metadata)` and use the returned stream for upload
  - [ ] 2.3 Handle exiftool absence gracefully (best-effort per AD-6)
  - [ ] 2.4 Add `ExifProcessor` stubs to test helpers
  - [ ] 2.5 Add pipeline integration test verifying EXIF processing is called

- [ ] 3. Attach sidecar metadata to Media (AC: 4)
  - [ ] 3.1 Add `Metadata *domain.MediaMeta` field to `domain.Media`
  - [ ] 3.2 In streaming reader `Next()`, when a media entry is found, look ahead for its `.json` sidecar, parse it, attach to `Media.Metadata`
  - [ ] 3.3 Update takeout tests for sidecar attachment

- [ ] 4. Persist file_name in state tracking (AC: 5, 6)
  - [ ] 4.1 Change `processMedia` to call `State.RecordFull()` instead of `State.Record()`
  - [ ] 4.2 Verify `albums-finalize` `fileNameToFileID` map is populated
  - [ ] 4.3 Update test stubs to expect `RecordFull` calls

- [ ] 5. Resume support in archive-mode (AC: 7)
  - [ ] 5.1 Before `uploadAll`, if `--resume`, call `State.PendingFiles()` and skip completed
  - [ ] 5.2 Update `fileIDMap` from existing file states on resume
  - [ ] 5.3 Add test for resume with archive-mode

- [ ] 6. Regression verification (AC: 8)
  - [ ] 6.1 Run `go test ./...`
  - [ ] 6.2 Run `go vet ./...`
  - [ ] 6.3 Run `golangci-lint run ./...`

## Dev Notes

### Architecture constraints (from ARCHITECTURE-SPINE.md)

- **AD-2 (Hexagonal)**: Pipeline only references port interfaces. Composition happens in `root.go`.
- **AD-6 (EXIF)**: exiftool is best-effort. Log warning, proceed with unmodified stream.
- **AD-8 (Dependency Direction)**: No adapter imports another adapter.
- **AD-9 (State Machine)**: `RecordFull` is the same state machine pattern.

### Sidecar attachment approach

When `Next()` finds a media file in the tar stream, it should peek ahead for a `.json` file with the same base name. If found, parse it via `ParseSidecar()` and attach it to `domain.Media.Metadata`. This avoids changing the port interface.

### Testing strategy

- Pipeline integration test using real `takeout.NewStreamReader` + fake uploader + fake state
- EXIF processor call verified with test double
- Resume test: set up state with mix of done/pending, verify only pending processed
- `albums-finalize` mapping: run pipeline, verify `fileNameToFileID` built correctly

### Files to touch

| File | Change |
|---|---|
| `cmd/gphoto2proton/root.go` | Replace sync stub with real pipeline composition |
| `cmd/gphoto2proton/root_test.go` | Update tests for real pipeline |
| `cmd/gphoto2proton/pipeline.go` | Add `ExifProcessor` field; wire EXIF call; switch to `RecordFull` |
| `cmd/gphoto2proton/pipeline_test.go` | Add EXIF/RecordFull tests |
| `internal/domain/photo.go` | Add `Metadata *domain.MediaMeta` field |
| `internal/takeout/stream.go` | Attach parsed sidecar metadata to `Media.Metadata` |
| `internal/takeout/takeout_test.go` | Update for sidecar attachment |

### References

- [Source: ARCHITECTURE-SPINE.md] AD-2, AD-6, AD-8, AD-9
- [Source: cmd/gphoto2proton/root.go:75-83] Current stub
- [Source: cmd/gphoto2proton/pipeline.go:33-41] Pipeline struct
- [Source: cmd/gphoto2proton/pipeline.go:99-119] processMedia
- [Source: cmd/gphoto2proton/root.go:120-130] albums-finalize mapping
- [Source: internal/port/exif.go:29-31] ExifProcessor interface
- [Source: internal/state/sqlite.go:142-154] RecordFull
