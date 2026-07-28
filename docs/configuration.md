# Configuration

gphoto2proton is configured entirely through CLI flags — no config file needed.
Below is a reference for all available options and their behavior.

---

## Command-Line Flags

### `--takeout-dir` (required)

Path to the extracted Google Takeout directory.

The directory must contain the `Google Photos/` or equivalent structure as
produced by Google Takeout extraction.

```bash
gphoto2proton sync --takeout-dir ~/Takeout/Takeout
```

---

### `--album-recreate` (optional)

When set, the tool recreates your Google Photos albums inside Proton Photos
after uploading all media.

```bash
gphoto2proton sync --takeout-dir ~/Takeout --album-recreate
```

Without this flag, albums are skipped.

---

### `--resume` (optional)

Skip already-completed files and retry any that failed in a previous run.

```bash
gphoto2proton sync --takeout-dir ~/Takeout --resume
```

Requires a state database from a previous run (see `--state-dir`).

---

### `--state-dir` (optional)

Directory for the SQLite state database. The database tracks per-file progress
and album state, enabling resume.

| Aspect | Detail |
|--------|--------|
| Default | `~/.gphoto2proton/state/` |
| Driver | SQLite (pure Go, no CGo required) |
| Tables | `file_states`, `album_states` |
| Persistence | Survives machine restarts |

```bash
gphoto2proton sync --takeout-dir ~/Takeout --state-dir /mnt/external/proton-state
```

---

## State Database Schema

### `file_states`

| Column | Type | Description |
|--------|------|-------------|
| `file_id` | TEXT (PK) | File identifier |
| `session_id` | TEXT | Migration session identifier |
| `state` | INTEGER | 0=Pending, 1=Processing, 2=Uploaded, 3=Failed, 4=Skipped |
| `file_name` | TEXT | Original filename |
| `file_size` | INTEGER | File size in bytes |
| `error_msg` | TEXT | Error description if failed |
| `updated_at` | TEXT | Last update timestamp |

### `album_states`

| Column | Type | Description |
|--------|------|-------------|
| `album_id` | TEXT (PK) | Proton Photos album ID |
| `session_id` | TEXT (PK) | Migration session identifier |
| `state` | INTEGER | 5=AlbumAttached |
| `updated_at` | TEXT | Last update timestamp |

---

## Credential Storage

Proton credentials are stored in `~/.gphoto2proton/credentials.json`.

This file contains:

- `UID` — Session UID
- `AccessToken` — Proton access token
- `RefreshToken` — Proton refresh token
- `SaltedKeyPass` — Salted key passphrase

Tokens are maintained by the Proton-API-Bridge SDK and refreshed automatically.

To clear stored credentials:

```bash
rm -rf ~/.gphoto2proton
```

The next run will prompt for credentials again.
