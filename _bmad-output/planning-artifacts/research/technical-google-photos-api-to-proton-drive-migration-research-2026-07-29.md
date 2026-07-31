---
stepsCompleted: [1, 2]
inputDocuments: []
workflowType: 'research'
lastStep: 2
research_type: 'technical'
research_topic: 'Google Photos API to Proton Drive migration - streaming album-by-album approach'
research_goals: 'Evaluate feasibility of extracting photos via Google Photos API directly, fixing EXIF data, and uploading to Proton Drive with multi-threaded streaming to preserve local disk space'
user_name: 'mmornati'
date: '2026-07-29'
web_research_enabled: true
source_verification: true
---

# Research Report: Technical

**Date:** 2026-07-29
**Author:** mmornati
**Research Type:** Technical

---

## Research Overview

Technical feasibility study for adding a Google Photos API-based ingestion path to the existing gphoto2proton Go CLI tool, alongside the current Takeout tar/tgz reader.

---

## Technical Research Scope Confirmation

**Research Topic:** Google Photos API to Proton Drive migration - streaming album-by-album approach
**Research Goals:** Evaluate feasibility of extracting photos via Google Photos API directly, fixing EXIF data, and uploading to Proton Drive with multi-threaded streaming to preserve local disk space

**Technical Research Scope:**

- Architecture Analysis - design patterns, frameworks, system architecture
- Implementation Approaches - development methodologies, coding patterns
- Technology Stack - languages, frameworks, tools, platforms
- Integration Patterns - APIs, protocols, interoperability
- Performance Considerations - scalability, optimization, patterns

**Research Methodology:**

- Current web data with rigorous source verification
- Multi-source validation for critical technical claims
- Confidence level framework for uncertain information
- Comprehensive technical coverage with architecture-specific insights

**Scope Confirmed:** 2026-07-29

---

## Technology Stack Analysis

### Existing Project Architecture

The project (`gphoto2proton`) already exists as a Go 1.26.5 CLI tool using hexagonal (ports & adapters) architecture:

| Component | Technology | Purpose |
|-----------|-----------|---------|
| CLI | Cobra (`spf13/cobra`) | Command-line interface |
| Domain | Pure Go structs | Core types: `Media`, `Album`, `MediaMeta`, `State` |
| Ports | Go interfaces | `TakeoutReader`, `ProtonUploader`, `ExifProcessor`, `StateTracker` |
| Takeout | Go `archive/tar` + `compress/gzip` | Streaming tar/tgz reader |
| EXIF | `exiftool` (system dep) | External subprocess for EXIF restoration |
| Proton | `Proton-API-Bridge` SDK | Upload to Proton Drive + Photos albums |
| State | `modernc.org/sqlite` (pure Go) | SQLite state persistence for resume |

### Google Photos Library API (current state)

**CRITICAL FINDING — March 31, 2025 breaking change:**

The Google Photos Library API was significantly restricted. Key changes:
- **Only app-created content** is now accessible via the Library API
- `photoslibrary.readonly` scope **removed** — can no longer list all user photos
- `photoslibrary` and `photoslibrary.sharing` scopes **removed**
- Remaining scopes: `photoslibrary.readonly.appcreateddata`, `photoslibrary.appendonly`, `photoslibrary.edit.appcreateddata`
- For user-uploaded content (not created by your app), use the **Picker API** (UI-based, not suitable for automation)
- Quota: 10,000 API requests/day + 75,000 media byte downloads/day per project

*Source: https://developers.google.com/photos/support/updates*

### Google Photos Picker API

The Picker API is a **client-side UI flow** — user selects photos/albums through a Google-provided picker widget. It returns media item IDs but is:
- Interactive (requires user to manually select)
- Not suitable for bulk automated migration
- Per-session, no programmatic bulk access

*Source: https://developers.googleblog.com/en/google-photos-picker-api-launch-and-library-api-updates/*

### Existing Takeout Approach (current implementation)

Current `port.TakeoutReader` interface:
```go
type TakeoutReader interface {
    Next(ctx context.Context) (*domain.Media, io.ReadCloser, error)
    AlbumManifest(ctx context.Context) ([]domain.Album, error)
}
```

The existing takeout adapter streams from tar/tgz archives entry-by-entry, classifying files as media, sidecar JSON, or album metadata. A Google Photos API adapter would implement the **same interface**.

### Proton Drive Upload Options

| Approach | Status | Notes |
|----------|--------|-------|
| `Proton-API-Bridge` SDK | **Currently used** | Go SDK, integrated in the project |
| `@protontech/drive-sdk` (Node.js) | Available | v0.14+, with stream upload, progress, pause/resume |
| Proton Drive CLI tool | In development (Q2 2026+) | Not yet production-ready for third-party use |

*Source: https://proton.me/blog/drive-sdk-january-2026, https://proton.me/blog/drive-sdk-june-2026*

### EXIF Handling Options

| Library | Language | Pros | Cons |
|---------|----------|------|------|
| `exiftool` | Perl (system) | **Currently used**, comprehensive | External dependency, subprocess overhead |
| `piexif` | Python | Pure Python, read/write EXIF in JPEG/WebP | Not Go, adds Python dependency |
| Go native EXIF | Go | No external deps | Limited write support, immature ecosystem |

*Source: https://piexif.readthedocs.io/en/latest/*

### Concurrency Patterns for Streaming

| Pattern | Best For | Notes |
|---------|----------|-------|
| `asyncio` (Python) | I/O-bound concurrent downloads | Requires `aiohttp`/`httpx` |
| Go goroutines + channels | **Existing Go project** | Native, lightweight, ideal for pipeline |
| `errgroup` (Go) | Bounded parallel ops | Built-in `golang.org/x/sync/errgroup` |
| Worker pools | Rate-limited API calls | Essential for Google Photos API quota mgmt |

*Source: https://abhay.fyi/blog/concurrent-downloads-with-python-using-asyncio-or-thread-pools/*

### Technology Adoption Summary

The key challenge is not the technology stack (Go is well-suited) but the **Google Photos API restriction** that prevents programmatic access to user-uploaded photo libraries. The Takeout approach remains the only viable bulk migration path for non-app-created content.

---

<!-- Content will be appended sequentially through research workflow steps -->
