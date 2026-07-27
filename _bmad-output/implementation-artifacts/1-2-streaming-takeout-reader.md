# Story 1.2: Streaming Takeout Archive Reader

Status: ready-for-dev

## Story

As a user migrating from Google Photos,
I want gphoto2proton to read my Takeout tar/tgz archives without extracting them to disk,
so that I don't need double the disk space for migration.

## Acceptance Criteria

1. Given a valid Takeout tar archive, When streaming Next() is called, Then each media file + its JSON sidecar is returned
2. Given a multi-part Takeout archive (001.tar, 002.tar...), When streaming across the boundary, Then all parts are read transparently
3. Given a non-tar file, When Next() is called, Then an appropriate error is returned
4. Given an archive with no media, When Next() is called, Then io.EOF is returned
5. Given an archive containing a JSON sidecar, When parsed, Then DateTimeOriginal, GPSLatitude, GPSLongitude, and Description are extracted
6. Given a corrupt tar entry, When encountered, Then the error is returned and stream position is not lost

## Tasks / Subtasks

- [ ] Implement internal/takeout/stream.go — tar/tgz streaming reader
  - [ ] TakeoutReader implementation with Next() returning (Media, io.ReadCloser, error)
  - [ ] Multi-part archive support (auto-detects .tar, .tgz, .tar.gz, 001.tar)
  - [ ] Sidecar JSON pairing — for each media file, locate corresponding .json sidecar
  - [ ] Skip non-media entries (directory entries, thumbnails)
- [ ] Implement internal/takeout/metadata.go — JSON sidecar parser
  - [ ] Parse Google Photos JSON format (title, photoTakenTime, geoData, description)
  - [ ] Map to domain.MediaMeta struct

## Dev Notes

### Package: internal/takeout/

**Architecture compliance (AD-8):** Implements `port.TakeoutReader`, imports only Go stdlib + port package.

**Key types:**
```go
// internal/takeout/stream.go
type Reader struct {
  readers []*tar.Reader
  current int
  media   []mediaEntry // populated by scanning JSON sidecars first
  mu      sync.Mutex
}

type mediaEntry struct {
  Name       string
  MediaPath  string // path within tar
  SidecarPath string // path within tar
  IsRaw      bool   // no sidecar
}

// internal/takeout/metadata.go
func ParseSidecar(r io.Reader) (*domain.MediaMeta, error)
```

**Takeout JSON sidecar format:**
```json
{
  "title": "IMG_1234.JPG",
  "photoTakenTime": {
    "timestamp": "1609459200",
    "formatted": "Jan 1, 2021, 12:00:00 AM UTC"
  },
  "geoData": {
    "latitude": 37.7749,
    "longitude": -122.4194,
    "altitude": 16.0
  },
  "description": "Golden Gate Bridge"
}
```

**Media file extension detection:** `.jpg`, `.jpeg`, `.png`, `.gif`, `.heic`, `.mov`, `.mp4`, `.cr2`, `.nef`, `.arw`

**Multi-part archive detection:** If `Takeout/` directory contains `part-001.tar`, `part-002.tar`, etc., read them in order.

**Important design note from Architecture Spine (AD-10):** The pipeline owns album accumulation. This adapter does NOT need to handle albums — it returns raw media streams. Album manifest extraction is a separate port method.

### Dependencies

None beyond Go stdlib (`archive/tar`, `compress/gzip`, `encoding/json`, `io`, `path/filepath`).

### Testing

- Unit test with a synthetic tar file containing 3 photos + sidecars
- Unit test with multi-part archive (2 tars)
- Unit test with corrupt tar entry — verify error returned + later entries readable
- Unit test with non-media file (directory, thumbnail, .Trashes)
- Unit test for sidecar parsing with full metadata

## References

- [Architecture Spine: AD-10 — Pipeline owns album accumulation]
- [Architecture Spine: Source Tree — internal/takeout/stream.go + metadata.go]
- [Product Brief: FR1 — Stream Takeout tar/tgz without extraction]
- [Epics.md: Epic 1 — Core Migration Pipeline]
