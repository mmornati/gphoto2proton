# Configuration

gphoto2proton is configured entirely through CLI flags — no config file needed.
Below is a reference for all available options and their behavior.

---

## Input Sources

Exactly one of the two input flags is required.

### `--takeout-archive` (recommended)

Path to a single Google Takeout `.tgz` or `.tar.gz` archive, exactly as
downloaded from Google. The archive is streamed entry-by-entry — **no
extraction is required**.

```bash
gphoto2proton sync --takeout-archive ~/Takeout/takeout-001.tgz
```

Use one `sync` run per archive. Album membership is accumulated across runs in
the state database, so albums that span multiple archives are handled
correctly.

### `--takeout-dir`

Path to an already-extracted Google Takeout directory (the directory containing
`Google Photos/` or the equivalent structure).

```bash
gphoto2proton sync --takeout-dir ~/Takeout/Takeout
```

The two flags are mutually exclusive; setting both is an error.

---

## Authentication

### `--username` (required on first run)

Your Proton account username (email address), e.g. `user@proton.me`.

### `--password` (required on first run)

Your Proton account password.

Both are only needed on the **first** run. After a successful login the session
is saved and reused automatically (see [Authentication](authentication.md) and
[Credential Storage](#credential-storage)).

---

## Other Options

### `--delete-after` (optional)

Only valid with `--takeout-archive`. Deletes the archive file after all of its
entries have been processed successfully. On failure, the archive is kept.

```bash
gphoto2proton sync --takeout-archive ~/Takeout/takeout-001.tgz --delete-after
```

### `--album-recreate` (optional)

Accepted for backward compatibility with the directory workflow. Album creation
is now automatic — albums found in the processed archive are created at the end
of each run, and `gphoto2proton albums-finalize` recreates the accumulated
cross-archive albums afterwards.

### `--resume` (optional)

Skip already-completed files and retry any that failed in a previous run.

```bash
gphoto2proton sync --takeout-archive ~/Takeout/takeout-001.tgz --resume
```

Requires a state database from a previous run (see `--state-dir`).

### `--state-dir` (optional)

Directory for the SQLite state database **and** the saved authentication
session.

| Aspect | Detail |
|--------|--------|
| Default | `~/.gphoto2proton/state/` |
| Driver | SQLite (pure Go, no CGo required) |
| Tables | `file_states`, `album_states`, `album_members` |
| Session | `session.json` (see [Credential Storage](#credential-storage)) |
| Persistence | Survives machine restarts |

```bash
gphoto2proton sync --takeout-archive ~/Takeout/takeout-001.tgz --state-dir /mnt/external/proton-state
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

### `album_members`

Accumulates album membership (`album_name`, `file_name`) across all sync runs.
This is what powers `gphoto2proton albums-finalize`.

---

## Credential Storage

The authenticated Proton session is stored in
`<state-dir>/session.json` (default: `~/.gphoto2proton/state/session.json`).

This file contains:

- `uid` — Session UID
- `accessToken` — Proton access token
- `refreshToken` — Proton refresh token
- `saltedKeyPass` — Salted key passphrase

Tokens are maintained by the Proton-API-Bridge SDK and refreshed automatically.
The file is written with owner-only permissions (`0600`) inside a `0700`
directory.

To clear the saved session (and force a fresh login on the next run):

```bash
rm -rf ~/.gphoto2proton/state
```

This also removes the state database — the next run will restart the migration
from scratch. To keep resume data but force re-login, delete only the session:

```bash
rm -f ~/.gphoto2proton/state/session.json
```

See [Authentication](authentication.md) for details on how login works,
including headless servers and 2FA. If your account has **2FA (TOTP)
enabled**, pass the current code with the `--twofa` flag on the first login.
