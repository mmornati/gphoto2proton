# Proton Photos API Probe

**Date:** 2026-07-27
**Probe script:** `cmd/probe/main.go`
**Status:** Framework created, human verification required

## Overview

This document captures the findings from probing the undocumented Proton Photos API to determine whether album creation is feasible for Epic 2.

## Method

1. Run `cmd/probe/main.go` with a valid Proton session:
   ```bash
   go run ./cmd/probe/
   ```
2. The probe uses saved credentials from `~/.gphoto2proton/session.json`
3. Probes multiple endpoints and reports HTTP status and response body

## Probe Endpoints

| Endpoint | Expected Purpose |
|---|---|
| `https://photos-api.proton.me` | Photos API root |
| `https://photos-api.proton.me/photos/v1/albums` | List/create albums |
| `https://photos-api.proton.me/photos/v1` | API version info |
| `https://drive-api.proton.me/drive/v1/albums` | Drive-based albums (fallback) |

## Expected API Patterns (Based on Proton API Conventions)

### Authentication

```http
Authorization: Bearer <access_token>
x-pm-uid: <session_uid>
Accept: application/json
```

### List Albums

```http
GET /photos/v1/albums
Authorization: Bearer <token>
```

Expected response:

```json
{
  "Albums": [
    {
      "ID": "string",
      "Name": "string",
      "PhotoCount": 0,
      "CoverPhotoID": "string"
    }
  ]
}
```

### Create Album

```http
POST /photos/v1/albums
Authorization: Bearer <token>
Content-Type: application/json

{
  "Name": "string"
}
```

Expected response:

```json
{
  "Code": 1000,
  "Album": {
    "ID": "string",
    "Name": "string"
  }
}
```

### Add Photos to Album

```http
POST /photos/v1/albums/{albumID}/photos
Authorization: Bearer <token>
Content-Type: application/json

{
  "PhotoIDs": ["string"]
}
```

### Duplicate Detection

Proton Photos likely deduplicates by file hash. Adding the same photo to an album twice should be idempotent.

## Risk Assessment

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Photos API doesn't exist | High — Epic 2 blocked | Low (Proton Photos is active product) | Probe confirms existence |
| API requires private beta access | High | Medium | Request access or use Drive API fallback |
| No album creation endpoint | High — album recreation blocked | Medium | Use Drive folders as album proxy |
| API rate limits | Medium | Low | Built-in retry in uploader |
| Breaking changes pre-GA | Medium | High | Version-pin API calls, integration tests |

## Viability Verdict

**⚠️ PENDING — Requires human to run probe script with valid session.**

Once the probe is run, update this document and epics.md with:

- Which endpoints returned 200 vs 4xx/5xx
- Whether album CRUD operations are available
- Whether to proceed with Epic 2 or switch to Drive folder-based album proxy

## How to Run

```bash
# 1. Authenticate first (if not already done)
gphoto2proton sync --help

# 2. Run the probe
cd /path/to/gphoto2proton
go run ./cmd/probe/

# 3. Report findings back update this file
```

## Alternative: Proton Drive Folder Proxy

If the Photos API does not support album creation, fall back to using Proton Drive folders as an album proxy:

```
/gphoto2proton/Albums/<AlbumName>/<photo>.jpg
```
