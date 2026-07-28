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
- 2026-07-28 — Review-driven fixes: dropped the unused `Album.Title` field (parsers only ever populate `Name`, which is what story 2-2's `ProtonUploader.CreateAlbum(name, fileIDs)` consumes); deleted the hollow `internal/domain/pipeline.go` (moved `AlbumHandler` to `internal/domain/album.go`); removed unused `Pipeline.Exif` / `Pipeline.State` fields; added nil-guards in `Pipeline.processMedia` for `media` and `rc`; replaced `fmt.Sscanf` in `parseUnixTimestamp` with `strconv.ParseInt`; removed dead `albumAccumulator.Date` field; centralized empty-album-name dropping in `Reader.mergeAlbums` so all three parsers share one rule. `go test ./... -race` passes (84 tests), `go vet ./...` clean. Note: pre-existing `gofmt -l` drift remains in `internal/domain/migration.go`, `internal/exif/processor.go`, and `internal/proton/upload.go` — out of scope for this fix.

## Review Findings (2026-07-28)

Triaged categories: `intent_gap`, `bad_spec`, `patch`, `defer`, `reject`. All four acceptance criteria are satisfied by the test suite; findings below are quality, architecture, and robustness issues.

### intent_gap

- [ ] [Review][intent_gap] Album.Name vs Album.Title semantic ambiguity — `internal/domain/album.go:27-28` The story only mentions `Name`, `FileIDs`, `CreatedAt` as the new fields but the existing `Title` field is still present and never assigned by any new code. There is no doc comment explaining when a future caller should set `Title` vs `Name`. The dev notes say "Title is preserved for story 2-2's CreateAlbum path" but the new parsers only ever populate `Name` — so `Title` will always be empty in any Album returned from `TakeoutReader`. This will silently break Proton `CreateAlbum` calls in story 2-2 unless resolved (either drop `Title`, repoint parsers to `Title`, or add doc comments).
- [ ] [Review][intent_gap] Pipeline lives in composition root instead of domain — `cmd/gphoto2proton/pipeline.go` vs `internal/domain/pipeline.go`. The architecture spine diagram (`ARCHITECTURE-SPINE.md` line 34-49) explicitly shows "Pipeline" inside the domain hexagon. Story note justifies composition-root placement because of an import cycle, but the actual `domain.Pipeline` struct was kept (now hollow and unused) and the new `cmd.Pipeline` type is the real implementation. Net effect: hexagonal layout is broken, and the domain `Pipeline` is dead code that will mislead future readers.

### bad_spec

- [ ] [Review][bad_spec] Story Dev Notes state `Name` is "original filenames from Takeout" — that's actually what `FileIDs` is. The `Name` field stores the album title parsed from the JSON `title` field. A reader of the story spec will misread the field's purpose. Add a clarifying sentence to the Dev Notes before story 2-2.
- [ ] [Review][bad_spec] Spec does not specify what `AlbumHandler` should do with Takeout-side file IDs vs Proton-internal file IDs. The current `cmd.Pipeline` returns `Name` + `FileIDs` (Takeout filenames) to the handler, but `ProtonUploader.CreateAlbum` is expected to receive Proton-internal file IDs per AD-10. Story 2-1 implicitly defers this translation to story 2-2 but the spec should call out the boundary explicitly.

### patch

- [ ] [Review][Patch] `parseUnixTimestamp` uses `fmt.Sscanf(s, "%d", &ts)` — `internal/takeout/metadata.go:189`. `Sscanf` silently truncates on fractional input (`"1625097600.5"` → 1625097600) and silently accepts trailing garbage (`"1625097600ms"` → 1625097600). Replace with `strconv.ParseInt(s, 10, 64)`. [internal/takeout/metadata.go:188-194]
- [ ] [Review][Patch] `bytesTrimSpace` reinvents stdlib — `internal/takeout/metadata.go:220-238`. Replace with `bytes.TrimSpace` from the stdlib (Go 1.21+; project targets 1.23+). [internal/takeout/metadata.go:220]
- [ ] [Review][Patch] `albumAccumulator.Date string` declared but never assigned — `internal/takeout/stream.go:46`. Dead field; remove it. [internal/takeout/stream.go:46]
- [ ] [Review][Patch] `Pipeline.Exif` and `Pipeline.State` declared but never used in `Run` — `cmd/gphoto2proton/pipeline.go:40-41`. Either remove the fields or wire them into the pipeline. As-is the struct claims responsibilities it doesn't fulfill (architecture spine AD-10/sequence diagram calls for both Exif and State calls inside the loop). [cmd/gphoto2proton/pipeline.go:38-44]
- [ ] [Review][Patch] `domain.Pipeline` is a hollow struct — `internal/domain/pipeline.go:26-32`. Only `OnAlbums` field exists, and `NewPipeline()` returns an empty instance. Nothing in the codebase uses it. Remove the file (or replace with a real domain-side pipeline constructor that does not create the import cycle). [internal/domain/pipeline.go]
- [ ] [Review][Patch] `Pipeline.processMedia` does not guard against `media == nil` or `rc == nil` — `cmd/gphoto2proton/pipeline.go:78-87`. The TakeoutReader port contract does not enforce non-nil `media`/`rc` on success; a misbehaving adapter would panic. Add a nil check before `media.Filename` and before `rc.Close()`. [cmd/gphoto2proton/pipeline.go:78]
- [ ] [Review][Patch] Parser/aggregator split on empty album name is inconsistent — `internal/takeout/metadata.go:90-141` return albums with `Name == ""`; `internal/takeout/stream.go:196` silently drops them. Centralize: either the parsers must reject, or `AlbumManifest` should reject, but not both with different rules. [internal/takeout/metadata.go:90-141, internal/takeout/stream.go:194-219]
- [ ] [Review][Patch] Add test asserting `AlbumManifest` is NOT called when upload fails — `cmd/gphoto2proton/pipeline_test.go`. Current `TestPipelinePropagatesUploadError` only checks the error return; adding `r.manifestCalls == 0` would lock in the post-upload ordering invariant. [cmd/gphoto2proton/pipeline_test.go:236-254]
- [ ] [Review][Patch] Add test asserting `AlbumManifest` is NOT called when reader `Next` errors mid-stream — `cmd/gphoto2proton/pipeline_test.go`. `TestPipelineReturnsReaderError` only checks the error. [cmd/gphoto2proton/pipeline_test.go:256-264]

### defer

- [x] [Review][Defer] `Pipeline.processMedia` discards the fileID returned by `Upload` — `cmd/gphoto2proton/pipeline.go:82`. Out of scope for story 2-1 (state recording is story 1-5). Deferred to story 2-2 / a future "state wiring" story. Pre-existing concern. [cmd/gphoto2proton/pipeline.go:82]
- [x] [Review][Defer] Tar path traversal (`Takeout/../etc/passwd`) not sanitized — `internal/takeout/stream.go:113`. Defense-in-depth concern; real risk depends on how the archive is sourced. Pre-existing pattern in this codebase. [internal/takeout/stream.go:113]
- [x] [Review][Defer] Album ordering in `AlbumManifest` is order-of-discovery across archive parts — `internal/takeout/stream.go:262-276`. Multi-part archives could yield different orders; downstream Proton calls likely don't care, but if determinism is needed later, sort by `Name` before returning. Pre-existing concern about deterministic output. [internal/takeout/stream.go:262]
- [x] [Review][Defer] `io.ReadAll` on `album.json` files can be large — `internal/takeout/stream.go:143,156,170`. Memory concern for very large album manifests. Could be replaced with bounded `io.LimitReader`. Pre-existing pattern; no current evidence of large album.json files in real Takeouts. [internal/takeout/stream.go:143]

### reject

- [x] [Review][Reject] `rc.Close()` errors silently dropped — `cmd/gphoto2proton/pipeline.go:79`. Standard Go pattern; `Close()` errors are widely accepted as best-effort. Not actionable.
- [x] [Review][Reject] `fakeUploader.CreateAlbum` stub not exercised by story 2-1 — `cmd/gphoto2proton/pipeline_test.go:188`. Required for interface compliance only. Story 2-2 will exercise it.
- [x] [Review][Reject] `IsTopLevelAlbumFile` returns true for any path whose directory does not contain a segment named "Albums" (case-insensitive). Could yield false positives for `MyAlbums/album.json` etc., but no evidence of Takeout exports with such directory names. Dismissed as theoretical.
- [x] [Review][Reject] `mediaExtensions` does not include `.heif` — `internal/takeout/metadata.go:14`. Out of scope for story 2-1 (album metadata is orthogonal to media extension coverage). Existing extension list unchanged from prior story.
