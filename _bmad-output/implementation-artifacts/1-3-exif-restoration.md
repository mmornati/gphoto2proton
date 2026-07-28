---
baseline_commit: "7bf308d"
---

# Story 1.3: EXIF Restoration via exiftool

Status: review

## Story

As a user migrating from Google Photos,
I want my photo metadata (DateTimeOriginal, GPS, description) restored from Takeout JSON sidecars,
so that my Proton Photos library has correct timestamps and locations.

## Acceptance Criteria

1. Given a JPEG with a JSON sidecar containing photoTakenTime, When Process() is called, Then the output JPEG has correct EXIF DateTimeOriginal
2. Given a JPEG with GPS coordinates in the sidecar, When Process() is called, Then the output JPEG has GPSLatitude/GPSLongitude EXIF tags
3. Given a file with a description in the sidecar, When Process() is called, Then the output file has an ImageDescription EXIF tag
4. Given exiftool is not installed, When Process() is called, Then a clear error is returned telling the user to install exiftool
5. Given a RAW file (CR2, NEF, ARW), When Process() is called, Then embedded EXIF is updated via exiftool's -overwrite_original flag
6. Given a corrupt sidecar JSON, When Process() is called, Then the file passes through unchanged and a warning is logged

## Tasks / Subtasks

- [x] Implement internal/exif/processor.go
  - [x] Check exiftool availability on init (os/exec.LookPath)
  - [x] Construct exiftool command with -tagsFromFile (copy JSON-derived tags)
  - [x] Pipe media stream through exiftool subprocess
  - [x] Handle stdout/stderr from exiftool for success/failure detection
  - [x] Implement best-effort fallback: log WARN on failure, return unmodified stream

## Dev Notes

### Package: internal/exif/

**Architecture compliance (AD-6):** Subprocess via os/exec. Best-effort — failure does not block pipeline (log WARN, pass through unmodified).

**exiftool command pattern:**
```
exiftool -overwrite_original \
  -DateTimeOriginal="${timestamp}" \
  -GPSLatitude="${lat}" \
  -GPSLongitude="${lng}" \
  -ImageDescription="${desc}" \
  -
```

The `-` means read from stdin, write to stdout. This keeps the streaming pipeline intact.

**Timestamp conversion:** Google Photos `photoTakenTime.timestamp` is a Unix epoch string (e.g., "1609459200"). Convert to exiftool format: `2021:01:01 00:00:00`.

**GPS handling:** Google Photos stores as decimal degrees; exiftool expects decimal degrees for GPSLatitude/GPSLongitude.

**Supported media:** JPEG, PNG (XMP), HEIC, CR2, NEF, ARW, MOV, MP4 — exiftool supports all of these.

**Port interface:**
```go
// internal/port/exif.go
type ExifProcessor interface {
  Process(ctx context.Context, r io.Reader, meta *domain.MediaMeta) (io.ReadCloser, error)
}
```

### Dependencies

- exiftool (system dependency, not Go)
- Go stdlib: `os/exec`, `bytes`, `io`, `fmt`, `log/slog`

### Testing

- Table-driven test with synthetic sidecar data (various photoTakenTime formats, GPS coords, descriptions)
- Mock exiftool binary for CI testing (shell script that copies stdin to stdout)
- Error case: missing exiftool
- Error case: corrupt sidecar
- Edge case: timestamp = 0
- Edge case: GPS = 0,0 (valid location)
- Edge case: empty description

## References

- [Architecture Spine: AD-6 — exiftool exec]
- [Architecture Spine: Source Tree — internal/exif/processor.go]
- [Product Brief: FR3 — Restore EXIF via exiftool]
- [Product Brief: Success Criteria — Metadata accuracy validated]
