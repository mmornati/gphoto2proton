# Commands Reference

## gphoto2proton

**Usage:** `gphoto2proton [command] [flags]`

**Available commands:**

| Command | Description |
|---------|-------------|
| `sync` | Run the migration pipeline against a Takeout archive or directory |
| `albums-finalize` | Create albums in Proton Photos from accumulated membership data |
| `version` | Print the version number |
| `help` | Help about any command |
| `completion` | Generate shell autocompletion scripts |

**Global flags:**

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help |

---

## gphoto2proton sync

Run the migration pipeline against a Google Takeout archive or an extracted
directory.

**Usage:**

```bash
gphoto2proton sync [flags]
```

**Flags:**

| Flag | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `--takeout-archive` | `string` | — | One of | Path to a single `.tgz` / `.tar.gz` Takeout archive (no extraction needed) |
| `--takeout-dir` | `string` | — | One of | Path to an already-extracted Google Takeout directory |
| `--delete-after` | `bool` | `false` | No | Delete the archive file after it was processed successfully |
| `--username` | `string` | — | Yes* | Proton account username (email) for the first login |
| `--password` | `string` | — | Yes* | Proton account password for the first login |
| `--twofa` | `string` | — | Only if 2FA* | Proton account TOTP code from your authenticator app (first login only) |
| `--resume` | `bool` | `false` | No | Skip completed files and retry failed ones |
| `--state-dir` | `string` | `~/.gphoto2proton/state` | No | Directory for the SQLite state database and saved session |
| `--album-recreate` | `bool` | `false` | No | Accepted for backward compatibility (albums are now created automatically) |

> *`--username` and `--password` are required only on the **first** run. The
> authenticated session is saved to `session.json` inside `--state-dir` and
> reused automatically on later runs — you can then omit both flags.
> If the account has **2FA (TOTP) enabled**, pass the current code with
> `--twofa` on the first login.
>
> Exactly one of `--takeout-archive` or `--takeout-dir` must be provided.

**Input modes:**

| Mode | Flag | When to use |
|------|------|-------------|
| Archive (recommended) | `--takeout-archive <file.tgz>` | Work directly on `.tgz` files as downloaded from Google — no extraction, no extra disk space |
| Directory | `--takeout-dir <dir>` | Point at an already-extracted `Takeout/` directory |

**Examples — archive mode (no extraction):**

```bash
# Process a single archive
gphoto2proton sync \
  --takeout-archive takeout-20260101T120000Z-001.tgz \
  --username user@proton.me --password 'secret'

# Process one archive at a time, deleting it after success
# (album membership accumulates across archives in the state database)
gphoto2proton sync --takeout-archive takeout-001.tgz --username user@proton.me --password 'secret' --delete-after
gphoto2proton sync --takeout-archive takeout-002.tgz --delete-after
gphoto2proton sync --takeout-archive takeout-003.tgz --delete-after

# Later runs reuse the saved session: credentials are no longer needed
gphoto2proton sync --takeout-archive takeout-004.tgz --resume
```

**Examples — directory mode (extracted):**

```bash
# Basic sync
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --username user@proton.me --password 'secret'

# Resume a previous run
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --resume

# Custom state directory
gphoto2proton sync \
  --takeout-dir ~/Takeout/Takeout \
  --state-dir /mnt/external/proton-state
```

---

## gphoto2proton albums-finalize

Create albums in Proton Photos from album membership data that was accumulated
in the state database while processing archives.

When you migrate several Takeout archives (one per `sync` run), albums that
span multiple archives are only fully known after the last archive has been
processed. Run this command once, after all `sync` runs, to create every
accumulated album and attach the correct photos.

**Usage:**

```bash
gphoto2proton albums-finalize [flags]
```

**Flags:**

| Flag | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `--state-dir` | `string` | `~/.gphoto2proton/state` | No | Directory with the state database created by `sync` |
| `--username` | `string` | — | Yes* | Proton account username (email) |
| `--password` | `string` | — | Yes* | Proton account password |
| `--twofa` | `string` | — | Only if 2FA* | Proton account TOTP code from your authenticator app (first login only) |

> *Credentials are only needed on the first run (or after clearing the saved
> session); see [Authentication](authentication.md). If the account has
> **2FA (TOTP) enabled**, pass the current code with `--twofa` on the first
> login.

**Example:**

```bash
gphoto2proton albums-finalize --username user@proton.me --password 'secret'
```

Albums that cannot be resolved (no matching uploaded file) are skipped with a
warning; the command never fails the whole run for a single album.

---

## gphoto2proton version

Print the version number.

**Usage:**

```bash
gphoto2proton version
```

**Example output:**

```
0.1.0
```

---

## gphoto2proton completion

Generate shell autocompletion scripts for bash, zsh, fish, or PowerShell.

**Usage:**

```bash
gphoto2proton completion <bash|zsh|fish|powershell>
```

**Example (zsh):**

```bash
source <(gphoto2proton completion zsh)
```

To make it permanent, add to your `~/.zshrc`:

```bash
source <(gphoto2proton completion zsh)
```
