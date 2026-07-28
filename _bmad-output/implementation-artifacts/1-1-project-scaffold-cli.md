---
baseline_commit: e9258cd5c8d327ee5402843f6874172718a10494
---

# Story 1.1: Project Scaffold + CLI Skeleton

Status: review

## Story

As a developer,
I want a Go project scaffold with a cobra CLI skeleton and the hexagon ports defined,
so that subsequent stories can implement adapters against stable interfaces.

## Acceptance Criteria

1. Running `gphoto2proton sync --help` prints usage with `--takeout-dir`, `--album-recreate`, `--resume` flags
2. Running `gphoto2proton version` prints the version string
3. Running `gphoto2proton sync` without flags fails with a missing-flag error
4. Running `go build ./cmd/gphoto2proton` produces a binary with zero errors
5. Each port interface compiles cleanly as a Go interface in its own file
6. Each adapter directory contains a stub constructor that returns an unimplemented error
7. MIT license header is present on every `.go` file and on `LICENSE`
8. `go mod tidy` completes without errors

## Tasks / Subtasks

- [x] Initialize Go module and set up `go.mod` (AC: 4, 8)
  - [x] `go mod init github.com/mmornati/gphoto2proton` (use Go 1.26)
  - [x] Add core dependencies: `github.com/spf13/cobra`, `modernc.org/sqlite`, `github.com/henrybear327/Proton-API-Bridge`, `github.com/ProtonMail/go-proton-api`
  - [x] Run `go mod tidy`

- [x] Create source tree per architecture spine (AC: 4)
  - [x] `cmd/gphoto2proton/main.go` — composition root
  - [x] `internal/domain/` — `photo.go`, `album.go`, `migration.go`, `pipeline.go`
  - [x] `internal/port/` — `takeout.go`, `exif.go`, `upload.go`, `state.go`
  - [x] `internal/takeout/stream.go`, `internal/takeout/metadata.go`
  - [x] `internal/exif/processor.go`
  - [x] `internal/proton/auth.go`, `internal/proton/upload.go`, `internal/proton/album.go`
  - [x] `internal/state/sqlite.go`, `internal/state/migrations.go`

- [x] Create domain types with zero external dependencies (AC: 5)
  - [x] `internal/domain/photo.go` — `Photo` struct
  - [x] `internal/domain/album.go` — `Album` struct
  - [x] `internal/domain/migration.go` — state enum constants
  - [x] `internal/domain/pipeline.go` — empty orchestrator skeleton

- [x] Define port interfaces referencing domain types (AC: 5)
  - [x] `internal/port/takeout.go` — `TakeoutReader` with `Next()`, `AlbumManifest()`
  - [x] `internal/port/exif.go` — `ExifProcessor` with `Process()`
  - [x] `internal/port/upload.go` — `ProtonUploader` with `Upload()`, `CreateAlbum()`
  - [x] `internal/port/state.go` — `StateTracker` with `Init()`, `Record()`

- [x] Create adapter stubs (AC: 6)
  - [x] Each adapter has a constructor that returns the port interface
  - [x] Each method returns `errors.New("not implemented")`

- [x] Create cobra CLI skeleton (AC: 1, 2, 3)
  - [x] Root command in `cmd/gphoto2proton/root.go`
  - [x] `sync` subcommand with flags: `--takeout-dir`, `--album-recreate`, `--resume`, `--state-dir`
  - [x] `version` subcommand
  - [x] Wire composition root in `main.go`

- [x] Add license headers (AC: 7)
  - [x] Create `LICENSE` from MIT template with year 2026, copyright mmornati
  - [x] Each `.go` file carries the MIT header

- [x] Create minimal README.md
  - [x] Project name, description, status, build instructions, dependency note (exiftool)

## Dev Notes

### Dependencies (go.mod)

```
module github.com/mmornati/gphoto2proton
go 1.26
require (
  github.com/spf13/cobra v1.10.2
  github.com/henrybear327/Proton-API-Bridge v1.0.4
  github.com/ProtonMail/go-proton-api v0.4.0
  modernc.org/sqlite v1.54.0
)
```

### Source Tree Alignment

Per [Architecture Spine AD-3 (cobra), AD-8 (dependency direction)]

```
gphoto2proton/
  cmd/gphoto2proton/
    main.go          # Composition root
    root.go          # cobra root + sync + version
  internal/
    domain/          # Go stdlib only — AD-2
      photo.go       # Photo struct
      album.go       # Album struct
      migration.go   # State enum
      pipeline.go    # Pipeline orchestrator skeleton
    port/            # Interfaces only, reference domain types — AD-11
      takeout.go
      exif.go
      upload.go
      state.go
    takeout/         # Stub — AD-8 direction
      stream.go
      metadata.go
    exif/
      processor.go
    proton/
      auth.go
      upload.go
      album.go
    state/
      sqlite.go
      migrations.go
  LICENSE
  README.md
```

### Architecture Compliance

- `internal/domain/` imports only Go stdlib (AD-2)
- `internal/port/` interfaces reference `domain.Photo`, `domain.Album` etc. (AD-11)
- Adapters import their port interface + external libs (AD-8)
- Composition root (`main.go`) imports ports + all adapters (AD-8)
- Everything is MIT-licensed (AD-7)
- CLI uses cobra exclusively (AD-3)

### Port Interface Signatures

```go
// internal/port/takeout.go
type TakeoutReader interface {
  Next(ctx context.Context) (*domain.Media, io.ReadCloser, error)
  AlbumManifest(ctx context.Context) ([]domain.Album, error)
}

// internal/port/exif.go
type ExifProcessor interface {
  Process(ctx context.Context, r io.Reader, meta *domain.MediaMeta) (io.ReadCloser, error)
}

// internal/port/upload.go
type ProtonUploader interface {
  Upload(ctx context.Context, name string, r io.Reader) (string, error)
  CreateAlbum(ctx context.Context, name string, fileIDs []string) (string, error)
}

// internal/port/state.go
type StateTracker interface {
  Init(ctx context.Context, sessionID string) error
  Record(ctx context.Context, fileID string, state domain.State) error
}
```

### CLI Flag Design

```
gphoto2proton sync --takeout-dir PATH [--album-recreate] [--resume] [--state-dir PATH]
gphoto2proton version
```

- `--takeout-dir` (string, required) — path to extracted Takeout directory
- `--album-recreate` (bool, default false) — no-op until Epic 2
- `--resume` (bool, default false) — skip completed, retry failed
- `--state-dir` (string, default `~/.gphoto2proton/state`) — SQLite db location
- Env var fallback via Viper: `GPHOTO2PROTON_TAKEOUT_DIR`, etc.

### Testing Requirements

- Root command help output test (`TestRootHelp`)
- Sync command missing flag test (`TestSyncMissingFlag`)
- Version output test (`TestVersionOutput`)
- All port interface compilation tests (each compiles with nil check)

### Docker / System Dependencies

- Go 1.26+ toolchain required
- exiftool documented as system dependency (not needed until story 1.3)

## References

- [Architecture Spine: AD-1 through AD-11]
- [Architecture Spine: Source Tree `## Structural Seed`]
- [Product Brief: `## Scope` section for v1 boundaries]
- [Epics.md: Epic 1 — Core Migration Pipeline]
- [Party Mode: Code Review Crew — cut `--album-recreate` no-op flag from Epic 1] → flag kept but documented as no-op until Epic 2

## Dev Agent Record

### Implementation Plan

1. **Module init**: `go mod init github.com/mmornati/gphoto2proton` with Go 1.26, then added cobra, sqlite, Proton-API-Bridge, and go-proton-api dependencies. Note: `Proton-API-Bridge v1.0.4` not available — used `v1.0.0` instead.
2. **Domain types**: `Photo`, `Media`, `MediaMeta` in `photo.go`; `Album` in `album.go`; `State` enum in `migration.go`; `Pipeline` skeleton in `pipeline.go`. Zero external deps.
3. **Port interfaces**: `TakeoutReader`, `ExifProcessor`, `ProtonUploader`, `StateTracker` in `internal/port/`. All reference domain types per AD-11.
4. **Adapter stubs**: `takeout.StreamReader` (port.TakeoutReader), `exif.Processor` (port.ExifProcessor), `proton.Uploader` (port.ProtonUploader), `state.SQLiteTracker` (port.StateTracker). Each constructor returns the port interface; every method returns `errors.New("not implemented")`.
5. **CLI skeleton**: `root.go` with root cmd, `sync` subcommand (flags: `--takeout-dir`, `--album-recreate`, `--resume`, `--state-dir`), and `version` subcommand. Main.go calls `Execute()`.
6. **Tests**: 4 CLI tests (`TestRootHelp`, `TestSyncMissingFlag`, `TestVersionOutput`, `TestSyncWithTakeoutDirSucceeds`) + 4 adapter compilation tests verifying nil-assignability to port interfaces.
7. **License**: MIT license in `LICENSE` file + MIT header on all 23 `.go` files.
8. **README**: Updated with build instructions, usage, status, dependency notes.

### Completion Notes

- All 8 acceptance criteria satisfied.
- All tasks and subtasks completed.
- `go build ./cmd/gphoto2proton` passes with zero errors.
- `go vet ./...` passes cleanly.
- `go test -count=1 ./...` passes (8 tests in 7 packages).
- `go mod tidy` completes without errors.
- Dependency version note: `github.com/henrybear327/Proton-API-Bridge` specified as v1.0.4 in Dev Notes but only v1.0.0 exists — used v1.0.0. `github.com/ProtonMail/go-proton-api` v0.4.0 resolved correctly.

### Debug Log

- Go 1.26.5 toolchain detected.
- Initial `go get github.com/henrybear327/Proton-API-Bridge@v1.0.4` failed (version not found); resolved by using `v1.0.0`.
- Import cycle detected in `internal/port/port_test.go` (port pkg importing adapter pkgs which import port) — resolved by moving compilation tests to respective adapter packages.
- Cobra v1.10.2 flag state leakage: `--help` flag set to `true` during `TestRootHelp` persisted to `TestSyncMissingFlag`. Fixed by creating fresh command trees per test via `newRootCmd()` helper.

## File List

### Created
- `cmd/gphoto2proton/main.go` — Composition root
- `cmd/gphoto2proton/root.go` — Cobra root, sync, and version commands
- `cmd/gphoto2proton/root_test.go` — CLI tests (help, missing flag, version, success)
- `internal/domain/photo.go` — Photo, Media, MediaMeta structs
- `internal/domain/album.go` — Album struct
- `internal/domain/migration.go` — State enum constants
- `internal/domain/pipeline.go` — Pipeline orchestrator skeleton
- `internal/port/takeout.go` — TakeoutReader interface
- `internal/port/exif.go` — ExifProcessor interface
- `internal/port/upload.go` — ProtonUploader interface
- `internal/port/state.go` — StateTracker interface
- `internal/takeout/stream.go` — StreamReader stub
- `internal/takeout/metadata.go` — MetadataParser stub
- `internal/takeout/takeout_test.go` — Compilation test
- `internal/exif/processor.go` — Processor stub
- `internal/exif/exif_test.go` — Compilation test
- `internal/proton/auth.go` — Authenticator stub
- `internal/proton/upload.go` — Uploader stub
- `internal/proton/album.go` — AlbumManager stub
- `internal/proton/proton_test.go` — Compilation test
- `internal/state/sqlite.go` — SQLiteTracker stub
- `internal/state/migrations.go` — Migrator stub
- `internal/state/state_test.go` — Compilation test
- `go.mod` — Module definition
- `go.sum` — Dependency checksums
- `LICENSE` — MIT license

### Modified
- `README.md` — Updated with build instructions and usage

## Change Log

- 2026-07-27: Implemented Story 1.1 — project scaffold, domain types, port interfaces, adapter stubs, cobra CLI skeleton, tests, license headers, README
