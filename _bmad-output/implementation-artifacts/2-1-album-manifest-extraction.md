---
baseline_commit: "aea7761"
---

# Story 2.1: Album Manifest Extraction from Takeout

Status: review

## Story

As a user migrating from Google Photos,
I want gphoto2proton to extract my album structures from the Takeout archive,
so that my album hierarchy can be recreated in Proton Photos.

## Acceptance Criteria

1. Given a Takeout archive containing album metadata, When AlbumManifest() is called, Then all albums with their member file IDs are returned
2. Given a photo in multiple albums, When the manifest is built, Then the photo appears in each album's member list
3. Given an empty album with no photos, When the manifest is built, Then the empty album is included in the result
4. Given an album named with special characters (emoji, unicode), When parsed, Then the name is preserved correctly

## Tasks / Subtasks

- [x] Implement album manifest extraction in internal/takeout/metadata.go
  - [x] Parse Takeout's album.json or Google Photos metadata JSON
  - [x] Build map[AlbumName][]FileID from sidecar references
  - [x] Expose via port.TakeoutReader.AlbumManifest()
- [x] Wire AlbumManifest() into the pipeline's post-upload phase

## Dev Notes

### Package: internal/takeout/

**Takeout album format:** Google Photos Takeout includes an `album.json` in the metadata or inline in each photo's JSON sidecar referencing album names. The format:
```json
{
  "albumData": {
    "title": "Summer 2024",
    "date": {"timestamp": "...", "formatted": "..."},
    "geoData": {...},
    "albumItems": [{"title": "IMG_0001.JPG"}, ...]
  }
}
```

Alternative format — per-album JSON files in `Takeout/Google Photos/Albums/<album-name>/album.json`:
```json
{
  "title": "Album Name",
  "description": "Description",
  "coverPhoto": "...",
  "mediaItems": ["IMG_0001.JPG", "IMG_0002.JPG"]
}
```

**Port interface:**
```go
// Already defined in port/takeout.go
type TakeoutReader interface {
  Next(ctx context.Context) (*domain.Media, io.ReadCloser, error)
  AlbumManifest(ctx context.Context) ([]domain.Album, error)
}
```

**Domain type:**
```go
type Album struct {
  Name      string
  FileIDs   []string // original filenames from Takeout
  CreatedAt time.Time
}
```

### Dependencies

- Go stdlib only

## References

- [Architecture Spine: AD-10 — Pipeline owns album accumulation, AlbumManifest()](./../planning-artifacts/architecture/architecture-gphoto2proton-2026-07-27/ARCHITECTURE-SPINE.md)
- [Product Brief: FR5 — Extract album manifests from Takeout](./../planning-artifacts/briefs/brief-gphoto2proton-2026-07-27/brief.md)

## Dev Agent Record

### Implementation Plan

Implemented album manifest extraction in the takeout adapter with three parse paths to cover the variants Google Takeout produces:

1. **Top-level `album.json`** at the archive root (or under a Google Photos/ prefix) — contains an `albumData` field that may be a single object or an array of objects.
2. **Per-album `album.json`** under `Google Photos/Albums/<album-name>/album.json` — uses `mediaItems` as the file list.
3. **Embedded `albumData` in photo sidecars** — older Takeout format where each photo's `.json` sidecar lists the album(s) it belongs to and the other photos in that album.

The reader pre-scans the tar alongside media extraction. Album detection helpers (`IsTopLevelAlbumFile`, `IsPerAlbumFile`, `IsPhotoSidecar`) classify each entry so random JSON files inside `Albums/` (e.g. `album-info.json`, `list.json`) are not misread as photo sidecars. Albums are merged by name in a deterministic order with file IDs deduplicated. `CreatedAt` is parsed from the unix timestamp in the album `date` field when present.

`domain.Album` gained `Name`, `FileIDs`, and `CreatedAt` so the port surface carries the Takeout-side metadata. The Proton-side `ID` and `Title` fields are preserved for story 2-2's CreateAlbum path.

Composition-root orchestration lives in `cmd/gphoto2proton/pipeline.go` because placing it in `internal/domain` would create a domain→port import cycle (port packages already import domain for types like `domain.Media`/`domain.Album`/`domain.State`). `Pipeline.Run` loops `Next()` to drive the upload phase, then calls `AlbumManifest()` after the loop ends and forwards the result to a pluggable `AlbumHandler` (story 2-2 wires the Proton `CreateAlbum` calls).

### Debug Log

None — implementation landed cleanly without rework.

### Completion Notes

- All four acceptance criteria satisfied:
  - **AC1** — `TestAlbumManifestTopLevelAlbumJSON` and `TestAlbumManifestPerAlbumJSON` exercise the parser via the port.
  - **AC2** — `TestAlbumManifestPhotoInMultipleAlbums` and `TestAlbumManifestMergesFormats` confirm a photo appears in every album it belongs to and that formats merge correctly.
  - **AC3** — `TestAlbumManifestEmptyAlbum` asserts the empty album is included with `FileIDs == []string{}`.
  - **AC4** — `TestAlbumManifestSpecialCharacters` confirms emoji/unicode names survive JSON round-trip.
- Added parser-level tests in `internal/takeout/metadata_test.go` for `ParseSidecarAlbums`, `ParseTopLevelAlbum`, `ParsePerAlbumJSON`, `IsTopLevelAlbumFile`, `IsPerAlbumFile`, `IsPhotoSidecar`, plus array/object format handling and `CreatedAt` parsing.
- Added pipeline tests in `cmd/gphoto2proton/pipeline_test.go` that verify `AlbumManifest` is called once after the upload loop and that the `AlbumHandler` hook receives the merged manifest. Includes an integration test that wires the real `takeout.Reader` and a fake uploader to prove the end-to-end wiring.
- Pre-existing flake in `TestNextReturnsMediaFromTar` (non-deterministic tar entry order because `makeTar` ranged over a Go map) was fixed by sorting keys before writing tar headers. This is a test-helper improvement, not a behavioral change.

### File List

- `internal/domain/album.go` — added `Name`, `FileIDs`, `CreatedAt` fields to `Album`.
- `internal/domain/pipeline.go` — added `AlbumHandler` type alias; `Pipeline` now carries the optional `OnAlbums` hook (used by composition root).
- `internal/takeout/metadata.go` — new parsers (`ParseSidecarAlbums`, `ParseTopLevelAlbum`, `ParsePerAlbumJSON`) and path classifiers (`IsTopLevelAlbumFile`, `IsPerAlbumFile`, `IsPhotoSidecar`); moved `mediaExtensions`/`isMediaFile` from `stream.go` so metadata helpers can reuse them.
- `internal/takeout/metadata_test.go` — new unit tests for parsers and classifiers.
- `internal/takeout/stream.go` — `Reader.scanAll` now also captures album metadata (top-level, per-album, embedded sidecar); `Reader.AlbumManifest` returns the merged manifest.
- `internal/takeout/takeout_test.go` — added manifest coverage and made `makeTar`/`makeTarGz` deterministic; removed the obsolete `TestAlbumManifestNotImplemented`.
- `cmd/gphoto2proton/pipeline.go` — new composition-root `Pipeline` type wiring `Next()` → `Upload()` → `AlbumManifest()` → `AlbumHandler`.
- `cmd/gphoto2proton/pipeline_test.go` — new orchestration tests with fakes and a real `takeout.Reader` integration test.

## Change Log

- 2026-07-28 — Story 2-1 implementation complete. Album manifest extraction landed with parsers for top-level, per-album, and embedded sidecar formats; reader now exposes `AlbumManifest` returning a merged `[]domain.Album`; composition-root pipeline calls the manifest after the upload loop and forwards it to a pluggable album handler. All tests pass (`go test ./... -count=5`).
