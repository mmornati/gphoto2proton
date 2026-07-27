# Story 2.1: Album Manifest Extraction from Takeout

Status: ready-for-dev

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

- [ ] Implement album manifest extraction in internal/takeout/metadata.go
  - [ ] Parse Takeout's album.json or Google Photos metadata JSON
  - [ ] Build map[AlbumName][]FileID from sidecar references
  - [ ] Expose via port.TakeoutReader.AlbumManifest()
- [ ] Wire AlbumManifest() into the pipeline's post-upload phase

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

- [Architecture Spine: AD-10 — Pipeline owns album accumulation, AlbumManifest()]
- [Product Brief: FR5 — Extract album manifests from Takeout]
