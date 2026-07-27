---
title: Product Brief — gphoto2proton
status: draft
created: 2026-07-27
updated: 2026-07-27
---

# Product Brief: gphoto2proton

## Executive Summary

gphoto2proton is a single-command CLI tool that migrates your entire Google Photos library to Proton Drive — streaming Takeout archives, restoring EXIF metadata from JSON sidecars, and recreating albums in Proton Photos. Moving photos out of Google Photos currently requires 4-5 separate tools, double the disk space, and a manual workflow that breaks for large libraries. Google's Takeout produces multi-gigabyte archives with metadata in separate JSON sidecars (EXIF is stripped in storage saver mode). Existing tools either can't handle albums (rclone), need separate post-processing (google-photos-takeout-helper), or target the wrong destination (Blober, CloudsLinker). Proton's own import is Windows-only. For 100GB+ libraries, the fear of permanently losing albums in an interrupted migration stops people from even starting. gphoto2proton is built as MIT open-source and fills this gap without ever needing full Takeout extraction.

## The Solution

A single binary: `gphoto2proton sync <takeout-dir> --album-recreate`

It streams Takeout archives tar-by-tar, restores EXIF metadata from JSON sidecars using exiftool in the same pass, uploads to Proton Drive via the official SDK, and recreates album structures in Proton Photos. State tracking makes it resume-safe. No intermediate extraction. No manual tool chaining.

## What Makes This Different

- **Streaming pipeline** — reads tar archives on-the-fly; no need for 2× disk space. Every competitor requires full extraction first.
- **In-stream EXIF restoration** — applies DateTimeOriginal and GPS from JSON sidecars during the upload pass, not as a second step.
- **Album recreation in Proton Photos** — the hardest unsolved problem. No existing tool does this.
- **Resume-safe** — tracks each file's state via a local SQLite database so an interrupted migration picks up where it left off.
- **macOS/Linux native** — fills the gap Proton hasn't addressed on macOS and Linux.

## Who This Serves

**Proton power users on macOS/Linux** with 50-500GB Google Photos libraries, CLI-comfortable, already paying for Proton Unlimited (~€10/mo). They value data ownership over convenience, and losing albums is the deciding factor keeping them locked in Google. Secondary: open-source contributors who want to help solve the album recreation problem.

## Success Criteria

- A user with a 100GB library can run `gphoto2proton sync` and walk away — photos land in Proton Drive with correct timestamps and albums intact.
- Interrupted runs resume without duplicating files.
- Metadata accuracy validated: DateTimeOriginal, GPS, description match Google Photos originals.

## Scope

**v1 includes:**
- Streaming tar/tgz Takeout parser
- EXIF DateTimeOriginal + GPS + description restoration via exiftool
- Proton Drive upload via official SDK
- Album metadata extraction from Takeout JSON
- Album recreation in Proton Photos
- Resume-safe state tracking
- MIT license

**Explicitly out of v1:**
- GUI / TUI (CLI only)
- Non-Proton targets (Ente, Immich, NAS)
- Media deduplication
- Incremental sync beyond initial migration
- Windows support

## Vision

gphoto2proton becomes the standard open-source tool for Google Photos → Proton migration — the "rclone for photo migration." If Proton never ships a macOS import tool, gphoto2proton fills that gap permanently. If they do, gphoto2proton still serves power users with features Proton won't build (album recreation, EXIF control, streaming, resume). Further down the road, the streaming + EXIF + album pipeline could be adapted for other destinations (Ente, Immich, self-hosted NAS) — but v1 goes deep on one flow and gets it right.
