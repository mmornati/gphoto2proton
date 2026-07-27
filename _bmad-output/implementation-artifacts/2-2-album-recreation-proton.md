# Story 2.2: Album Recreation in Proton Photos

Status: ready-for-dev

## Story

As a user migrating from Google Photos,
I want my albums recreated in Proton Photos,
so that my photo organization survives the migration.

## Acceptance Criteria

1. Given an album manifest with albums and member file IDs, When CreateAlbum() is called for each, Then albums appear in Proton Photos with correct member photos
2. Given a photo in multiple albums, When processed, Then the photo appears in each album in Proton Photos
3. Given 50+ albums, When processed sequentially, Then all albums are created without rate-limit errors
4. Given album creation fails for one album, When processing continues, Then errors are logged and remaining albums are still created

## Tasks / Subtasks

- [ ] Implement album recreation in internal/proton/album.go
  - [ ] CreateAlbum(name string, fileIDs []string) → albumID string
  - [ ] Add photos to album after creation
  - [ ] Map pipeline fileID → Proton fileID
  - [ ] Implement retry with backoff for rate limits
- [ ] Update pipeline.go's album phase to call ProtonUploader.CreateAlbum()
- [ ] Update state tracker to record album_attached state

## Dev Notes

### Package: internal/proton/

**Architecture compliance (AD-5, AD-10):** Album recreation is custom code in the same Proton adapter. Pipeline accumulates album→fileID mapping and calls CreateAlbum() post-upload.

**Proton Photos API (from story 1.6 probe):** The actual endpoint and format depends on the API probe results. Expected structure:
```go
func (a *AlbumAdapter) CreateAlbum(ctx context.Context, name string, fileIDs []string) (string, error) {
  // POST /photos/v1/albums
  // Response: {"albumID": "..."}
  // Then: POST /photos/v1/albums/{albumID}/photos
  // Body: {"photoIDs": [...]}
  // Map accumulated fileIDs to Proton fileIDs
}
```

**State tracking update:** After each album is created, the pipeline records:
```go
state.Record(ctx, albumID, domain.AlbumAttached)
```

**Error handling:** Album creation is best-effort per album. If album A fails but album B succeeds, album B is still created. Failed albums are logged and retried on next --resume.

**Rate limiting:** Proton API may throttle. Implement exponential backoff: 1s, 2s, 4s, 8s, max 30s.

### Dependency

This story depends on:
1. Story 1.6 — Proton Photos API probe (to know the exact endpoint schema)
2. Story 2.1 — Album manifest extraction (to have the data to recreate)

### Testing

- Integration test against actual Proton Photos (manual, flagged)
- Unit test with mock Proton API that confirms correct endpoint calls
- Edge case: album name already exists
- Edge case: empty album (no photos to add)
- Edge case: photo already in album (idempotent)
- Edge case: 50+ albums in parallel

## References

- [Architecture Spine: AD-10 — CreateAlbum(name, fileIDs), post-upload]
- [Architecture Spine: Deferred — album recreation reverse-engineering]
- [Product Brief: FR6 — Recreate albums in Proton Photos]
- [Assumption Audit: #2 — API existence risk flagged, probe needed first]
