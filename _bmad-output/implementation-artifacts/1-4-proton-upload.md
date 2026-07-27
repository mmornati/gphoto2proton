# Story 1.4: Proton Drive Upload

Status: ready-for-dev

## Story

As a user migrating to Proton,
I want processed photos uploaded to my Proton Drive,
so that my library is available in my Proton account.

## Acceptance Criteria

1. Given a valid Proton session, When Upload() is called with a media stream, Then the file appears in Proton Drive under a gphoto2proton folder
2. Given an expired session, When Upload() is called, Then re-authentication is attempted transparently
3. Given a network failure during upload, When retried, Then the upload resumes or is retried from scratch
4. Given invalid credentials, When Upload() is called, Then a clear authentication error is returned
5. Given successful upload, When the method returns, Then the returned fileID is non-empty

## Tasks / Subtasks

- [ ] Implement internal/proton/auth.go — authentication adapter
  - [ ] CLI-based OAuth flow via go-proton-api (user provides credentials or existing session cookie)
  - [ ] Token refresh handling
  - [ ] Session persistence (save to ~/.gphoto2proton/session.json)
- [ ] Implement internal/proton/upload.go — file upload adapter
  - [ ] Proton-API-Bridge upload with streamed content
  - [ ] Create gphoto2proton folder in Proton Drive root if not exists
  - [ ] Upload each file with correct filename and MIME type
  - [ ] Retry logic for transient failures (3 retries, exponential backoff)
- [ ] Implement internal/proton/album.go — album stub
  - [ ] CreateAlbum returns "not implemented" error (deferred to Epic 2)

## Dev Notes

### Package: internal/proton/

**Architecture compliance (AD-5):** Uses go-proton-api for auth, rclone/Proton-API-Bridge for file ops. Album code wrapped in the same adapter.

**go-proton-api v0.4+ key APIs:**
```go
// Auth flow
client := proton.New()
tlsClient := proton.NewTLSTransport()
session, err := client.NewSession(tlsClient, proton.AppVersion("gphoto2proton"))

// Login with credentials
auth, err := session.AuthClient().AuthVerifier(ctx, username, password)
// Wait for 2FA if needed
if auth.TwoFactorRequired {
  // Prompt user for TOTP code
  _, err = session.AuthClient().Auth2FA(ctx, proton.TOTP(totpCode))
}
```

**Proton-API-Bridge v1.0+ key APIs:**
```go
bridge, err := proton_api_bridge.NewBridge(session, proton_api_bridge.WithCreateFolder(true))
fileID, err := bridge.Upload(ctx, parentLinkID, filename, reader)
```

**Folder structure in Proton Drive:** `gphoto2proton/` at root. All uploaded files go there. v1 does not replicate Google Photos folder structure.

**Streaming consideration:** The upload adapter receives a stream. If the stream is already exhausted by a previous failed attempt, the adapter must buffer or re-read. Since EXIF processing produces a new stream per call, this is safe — each Upload() call gets a fresh reader.

**MIME type mapping:**
```go
var mimeTypes = map[string]string{
  ".jpg":  "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png":  "image/png",
  ".heic": "image/heic",
  ".mov":  "video/quicktime",
  ".mp4":  "video/mp4",
  ".cr2":  "image/x-canon-cr2",
  ".nef":  "image/x-nikon-nef",
  ".arw":  "image/x-sony-arw",
}
```

### Dependencies (go.mod)

- `github.com/ProtonMail/go-proton-api v0.4+`
- `github.com/henrybear327/Proton-API-Bridge v1.0+`

### Testing

- Unit test with mock Proton API (go-proton-api provides interfaces)
- Unit test for retry logic
- Unit test for token refresh
- Edge case: network timeout during upload
- Edge case: duplicate filename handling

## References

- [Architecture Spine: AD-5 — go-proton-api + Bridge]
- [Architecture Spine: Source Tree — internal/proton/]
- [Product Brief: FR4 — Upload to Proton Drive]
- [Market Research: Proton Drive SDK preview June 2026]
