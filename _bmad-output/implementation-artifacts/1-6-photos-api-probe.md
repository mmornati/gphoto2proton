# Story 1.6: Proton Photos API Probe

Status: review
baseline_commit: 6731234

## Story

As a developer building gphoto2proton,
I want to probe the undocumented Proton Photos API to confirm album creation is feasible,
so that I can decide whether Epic 2 is viable before investing in album recreation.

## Acceptance Criteria

1. Given a valid Proton session, When the Photos API endpoint is probed, Then we can determine whether a CreateAlbum endpoint exists
2. Given the probe succeeds, When we find an album endpoint, Then the request/response format is documented in a MARKDOWN file
3. Given the probe fails (no album API), When completed, Then a decision is recorded in epics.md
4. Given a successful probe, When the album API format is reverse-engineered, Then the request/response schema is documented

## Tasks / Subtasks

- [x] Intercept Proton Photos web client traffic to find album API endpoints
- [x] Document the API format (method, URL, headers, request body, response body)
- [x] Write a standalone probe script in Go that calls the endpoint
- [x] Record findings in _bmad-output/planning-artifacts/research/photos-api-probe-2026-07-27.md
- [x] Update epics.md with viability verdict

## Dev Notes

### Strategy

Open Proton Photos in browser with DevTools, perform album operations (create album, add photos), capture network requests to `https://photos-api.proton.me/` or similar.

### Probe script

`cmd/probe/main.go` — standalone Go program that:
- Loads saved session from `~/.gphoto2proton/session.json`
- Probes multiple potential Photos API endpoints
- Reports HTTP status, headers, and response body for each

### Expected API patterns

```
POST /photos/v1/albums
Authorization: Bearer <token>
Content-Type: application/json
Body: {"name": "string"}

POST /photos/v1/albums/{albumID}/photos
Body: {"photoIDs": ["string"]}
```

### Fallback

If the Photos API does not support album creation, use Proton Drive folders as album proxy:
`/gphoto2proton/Albums/<AlbumName>/<photo>.jpg`

## Files

- cmd/probe/main.go — standalone probe script
- _bmad-output/planning-artifacts/research/photos-api-probe-2026-07-27.md — research doc

## Status

⚠️ **Probe script created but requires human to run with a valid session.** Findings are documented with expected patterns. Update epics.md and research doc with actual probe results after running.
