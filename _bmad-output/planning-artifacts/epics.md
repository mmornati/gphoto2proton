---
stepsCompleted:
  - "step-01-validate-prerequisites"
  - "step-02-design-epics"
  - "step-02-advanced-elicitation"
inputDocuments:
  - "_bmad-output/planning-artifacts/briefs/brief-gphoto2proton-2026-07-27/brief.md"
  - "_bmad-output/planning-artifacts/architecture/architecture-gphoto2proton-2026-07-27/ARCHITECTURE-SPINE.md"
  - "_bmad-output/planning-artifacts/research/market-gphoto2proton-research-2026-07-27.md"
---

# gphoto2proton - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for gphoto2proton, decomposing the requirements from the Product Brief and Architecture decisions into implementable stories for a CLI tool that migrates Google Photos Takeout archives to Proton Drive with EXIF restoration and album recreation.

## Requirements Inventory

### Functional Requirements

FR1: Stream Takeout tar/tgz archives without fully extracting to disk
FR2: Parse JSON sidecar metadata (DateTimeOriginal, GPS, description) from Takeout archives
FR3: Restore EXIF metadata onto media files using exiftool during the stream
FR4: Upload processed photos to Proton Drive via the Proton SDK bridge
FR5: Extract album membership from Takeout album manifests
FR6: Recreate albums in Proton Photos with correct file membership
FR7: Track migration state per-file in SQLite for resume safety
FR8: Provide a single cobra CLI command with flags and help text
FR9: Support --album-recreate flag to enable/disable album recreation
FR10: Support --resume flag to continue an interrupted migration

### NonFunctional Requirements

NFR1: macOS and Linux support via Go cross-compilation
NFR2: MIT open-source license with proper headers
NFR3: No intermediate disk extraction — streaming pipeline only
NFR4: Single binary distribution with no runtime dependencies beyond exiftool
NFR5: Structured logging via log/slog with DEBUG/INFO/WARN/ERROR levels

### Additional Requirements

- Go 1.23+ as the implementation language
- Hexagonal architecture: domain ← ports ← adapters
- cobra CLI framework for command structure
- modernc.org/sqlite for state persistence (pure Go, no CGO)
- go-proton-api for Proton authentication
- rclone/Proton-API-Bridge for Proton file operations
- exiftool as a documented system dependency
- State machine: pending → processing → uploaded → album_attached → done + failed
- Source tree structure per architecture spine
- CLI flags + env var fallback via cobra/viper
- CI/CD via GitHub Actions with goreleaser (deferred)

### UX Design Requirements

N/A — CLI-only tool

### FR Coverage Map

FR1: Epic 1 - Stream Takeout archives without full extraction
FR2: Epic 1 - Parse JSON sidecar metadata
FR3: Epic 1 - Restore EXIF via exiftool
FR4: Epic 1 - Upload to Proton Drive
FR5: Epic 2 - Extract album manifests from Takeout
FR6: Epic 2 - Recreate albums in Proton Photos
FR7: Epic 1 - SQLite state tracking for resume
FR8: Epic 1 - cobra CLI with help and flags
FR9: Epic 1 --album-recreate flag (no-op in Epic 1)
FR10: Epic 1 --resume flag

## Epic List

### Epic 1: Core Migration Pipeline
User can run `gphoto2proton sync <takeout-dir>` and migrate all photos with correct metadata to Proton Drive, with resume-safe state tracking. The --album-recreate flag is accepted but acts as a no-op placeholder until Epic 2. Includes an early story to probe the Proton Photos API and validate album recreation feasibility before Epic 2 investment.
**FRs covered:** FR1, FR2, FR3, FR4, FR7, FR8, FR9, FR10
**NFRs covered:** All

### Epic 2: Album Recreation
Albums from Google Photos are recreated in Proton Photos with correct file membership, powered by the album manifest extracted during Epic 1's Takeout parsing.
**FRs covered:** FR5, FR6

## Story 1-6: Proton Photos API Probe Verdict

**Status:** ⚠️ PENDING — Requires human to run probe script

A probe script has been created at `cmd/probe/main.go` and API patterns documented in `_bmad-output/planning-artifacts/research/photos-api-probe-2026-07-27.md`.

**To decide Epic 2 viability, run:**
```bash
go run ./cmd/probe/
```

The probe will test:
- `https://photos-api.proton.me/photos/v1/albums` — expected album CRUD endpoint
- `https://drive-api.proton.me/drive/v1/albums` — fallback via Drive API

**Outcome scenarios:**
- **✅ Photos API supports albums:** Proceed with Epic 2 as planned
- **❌ No album API exists:** Use Proton Drive folders as album proxy (`/gphoto2proton/Albums/<Name>/`), adjust Epic 2 scope
