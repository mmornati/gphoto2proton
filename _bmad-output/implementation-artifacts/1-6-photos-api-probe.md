# Story 1.6: Proton Photos API Probe

Status: ready-for-dev

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

- [ ] Intercept Proton Photos web client traffic to find album API endpoints
- [ ] Document the API format (method, URL, headers, request body, response body)
- [ ] Write a standalone probe script in Go that calls the endpoint
- [ ] Record findings in _bmad-output/planning-artifacts/research/photos-api-probe-2026-07-27.md
- [ ] Update epics.md with viability verdict

## Dev Notes

**Strategy:** Open Proton Photos in browser with DevTools, perform album operations (create album, add photos), capture network requests to `https://photos-api.proton.me/` or similar.

**Expected approach (based on known Proton API patterns):**
```
POST /photos/v1/albums
Authorization: Bearer <token>
Content-Type: application/json
Body: {"name": "string"}

POST /photos/v1/albums/{albumID}/photos
Body: {"photoIDs": ["string"]}
```

**Authentication headers:** Extract from the existing go-proton-api session.

### Dependencies

- `github.com/ProtonMail/go-proton-api` (already in go.mod from story 1.4)
- Manual DevTools inspection (one-time)

## References

- [Architecture Spine: AD-5 — album recreation is custom code in same adapter]
- [Architecture Spine: Deferred — Album recreation reverse-engineering spike]
- [Assumption Audit: #1 + #2 — album independence unvalidated, API may not exist]
