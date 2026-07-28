# Installation

## Prerequisites

- **exiftool** — Required for EXIF metadata restoration. The tool degrades gracefully if absent, but EXIF data will not be processed.

  ```bash
  # macOS
  brew install exiftool

  # Ubuntu/Debian
  sudo apt install libimage-exiftool-perl

  # Fedora/RHEL
  sudo dnf install perl-Image-ExifTool

  # Arch Linux
  sudo pacman -S perl-image-exiftool
  ```

---

## Option 1: Homebrew (Recommended)

```bash
brew tap mmornati/gphoto2proton https://github.com/mmornati/gphoto2proton
brew install gphoto2proton exiftool

gphoto2proton version
```

To update later:

```bash
brew update && brew upgrade gphoto2proton
```

---

## Option 2: Pre-Built Binary

1. Go to the [Releases page](https://github.com/mmornati/gphoto2proton/releases)
2. Download the archive for your platform:
   - `gphoto2proton_<version>_darwin_amd64.tar.gz` — macOS (Intel)
   - `gphoto2proton_<version>_darwin_arm64.tar.gz` — macOS (Apple Silicon)
   - `gphoto2proton_<version>_linux_amd64.tar.gz` — Linux (x86_64)
   - `gphoto2proton_<version>_linux_arm64.tar.gz` — Linux (ARM64)
3. Extract and install:

   ```bash
   tar xzf gphoto2proton_*.tar.gz
   sudo mv gphoto2proton /usr/local/bin/
   gphoto2proton version
   ```

---

## Option 3: Build from Source

Requires [Go 1.26+](https://go.dev/dl/).

```bash
git clone https://github.com/mmornati/gphoto2proton.git
cd gphoto2proton
go build -o gphoto2proton ./cmd/gphoto2proton
sudo mv gphoto2proton /usr/local/bin/
gphoto2proton version
```

---

## Verify Installation

```bash
gphoto2proton version
```

Expected output:
```
0.1.0
```
