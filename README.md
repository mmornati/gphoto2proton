# gphoto2proton

Single-command CLI tool to migrate Google Photos Takeout archives to Proton Drive — with streaming, EXIF restoration, album recreation, and resume safety.

## Status

Active development. Core scaffold and CLI skeleton implemented.

## Prerequisites

- Go 1.26+
- [exiftool](https://exiftool.org/) (system dependency for EXIF restoration, required from story 1.3)

## Build

```bash
go build ./cmd/gphoto2proton
```

## Usage

```bash
gphoto2proton sync --takeout-dir ~/Takeout [--album-recreate] [--resume] [--state-dir ~/.gphoto2proton/state]
gphoto2proton version
```

## License

MIT
