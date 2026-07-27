# gphoto2proton

Single-command CLI tool to migrate Google Photos Takeout archives to Proton Drive — with streaming, EXIF restoration, album recreation, and resume safety.

## Status

Planning phase. Implementation stories ready in `_bmad-output/implementation-artifacts/`.

## Prerequisites

- Go 1.26+
- [exiftool](https://exiftool.org/) (system dependency for EXIF restoration)

## Quick Start

```bash
gphoto2proton sync --takeout-dir ~/Takeout --album-recreate
```

## License

MIT
