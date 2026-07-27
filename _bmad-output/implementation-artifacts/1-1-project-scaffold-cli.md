# Story 1.1: Project Scaffold + CLI Skeleton

Status: ready-for-dev

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

- [ ] Initialize Go module and set up `go.mod` (AC: 4, 8)
  - [ ] `go mod init github.com/mmornati/gphoto2proton` (use Go 1.26)
  - [ ] Add core dependencies: `github.com/spf13/cobra`, `modernc.org/sqlite`, `github.com/henrybear327/Proton-API-Bridge`, `github.com/ProtonMail/go-proton-api`
  - [ ] Run `go mod tidy`

- [ ] Create source tree per architecture spine (AC: 4)
  - [ ] `cmd/gphoto2proton/main.go` — composition root
  - [ ] `internal/domain/` — `photo.go`, `album.go`, `migration.go`, `pipeline.go`
  - [ ] `internal/port/` — `takeout.go`, `exif.go`, `upload.go`, `state.go`
  - [ ] `internal/takeout/stream.go`, `internal/takeout/metadata.go`
  - [ ] `internal/exif/processor.go`
  - [ ] `internal/proton/auth.go`, `internal/proton/upload.go`, `internal/proton/album.go`
  - [ ] `internal/state/sqlite.go`, `internal/state/migrations.go`

- [ ] Create domain types with zero external dependencies (AC: 5)
  - [ ] `internal/domain/photo.go` — `Photo` struct
  - [ ] `internal/domain/album.go` — `Album` struct
  - [ ] `internal/domain/migration.go` — state enum constants
  - [ ] `internal/domain/pipeline.go` — empty orchestrator skeleton

- [ ] Define port interfaces referencing domain types (AC: 5)
  - [ ] `internal/port/takeout.go` — `TakeoutReader` with `Next()`, `AlbumManifest()`
  - [ ] `internal/port/exif.go` — `ExifProcessor` with `Process()`
  - [ ] `internal/port/upload.go` — `ProtonUploader` with `Upload()`, `CreateAlbum()`
  - [ ] `internal/port/state.go` — `StateTracker` with `Init()`, `Record()`

- [ ] Create adapter stubs (AC: 6)
  - [ ] Each adapter has a constructor that returns the port interface
  - [ ] Each method returns `errors.New("not implemented")`

- [ ] Create cobra CLI skeleton (AC: 1, 2, 3)
  - [ ] Root command in `cmd/gphoto2proton/root.go`
  - [ ] `sync` subcommand with flags: `--takeout-dir`, `--album-recreate`, `--resume`, `--state-dir`
  - [ ] `version` subcommand
  - [ ] Wire composition root in `main.go`

- [ ] Add license headers (AC: 7)
  - [ ] Create `LICENSE` from MIT template with year 2026, copyright mmornati
  - [ ] Each `.go` file carries the MIT header

- [ ] Create minimal README.md
  - [ ] Project name, description, status, build instructions, dependency note (exiftool)

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
