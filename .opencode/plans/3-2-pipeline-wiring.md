# Story 3.2: Pipeline Wiring & Sync Command Completion

**Target file**: `_bmad-output/implementation-artifacts/3-2-pipeline-wiring.md`
**Epic**: 3 (Archive-Aware Streaming & Cross-Archive Albums)

## Acceptance Criteria

1. **Sync command is wired**: `gphoto2proton sync --takeout-archive <path.tgz>` composes `takeout.NewStreamReader(path)`, creates a `Pipeline`, and calls `Pipeline.Run()`. The `"(not yet implemented)"` stub in `root.go:75-83` is replaced.

2. **Directory mode preserved**: `--takeout-dir` flow also wired through the pipeline (was also a stub).

3. **`--delete-after` deletes on success**: Archive removed via `os.Remove()` after successful pipeline run. Not deleted on failure.

4. **EXIF processor wired**: `Pipeline` gains `ExifProcessor port.ExifProcessor` field. `processMedia` calls `exifProcessor.Process()` between `Next()` and `Upload()`.

5. **Filename to fileID persisted**: Pipeline calls `State.RecordFull()` instead of `State.Record()` so `file_name` column is populated for `albums-finalize`.

6. **`albums-finalize` works**: Maps filenames to Proton file IDs correctly from `FileStates("")`.

7. **`--resume` works**: Checks `State.PendingFiles()` in archive-mode.

8. **All existing tests pass**: 125+ tests + `go vet` + `golangci-lint`.

## Files to Touch

| File | Change |
|---|---|
| `cmd/gphoto2proton/root.go` | Replace sync stub with real pipeline composition; wire all adapters |
| `cmd/gphoto2proton/root_test.go` | Update tests for real pipeline execution |
| `cmd/gphoto2proton/pipeline.go` | Add `ExifProcessor` field; wire EXIF call; switch to `RecordFull` |
| `cmd/gphoto2proton/pipeline_test.go` | Add EXIF tests; update stubs |
| `internal/domain/photo.go` | Add optional `Metadata *domain.MediaMeta` field |
| `internal/takeout/stream.go` | Attach parsed sidecar metadata to `Media.Metadata` |
| `internal/takeout/takeout_test.go` | Update for sidecar attachment |
