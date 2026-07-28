# Commands Reference

## gphoto2proton

**Usage:** `gphoto2proton [command] [flags]`

**Available commands:**

| Command | Description |
|---------|-------------|
| `sync` | Run the migration pipeline |
| `version` | Print the version number |
| `help` | Help about any command |
| `completion` | Generate shell autocompletion scripts |

**Global flags:**

| Flag | Description |
|------|-------------|
| `-h, --help` | Show help |

---

## gphoto2proton sync

Run the migration pipeline against a Google Takeout archive.

**Usage:**

```bash
gphoto2proton sync [flags]
```

**Flags:**

| Flag | Type | Default | Required | Description |
|------|------|---------|----------|-------------|
| `--takeout-dir` | `string` | — | Yes | Path to extracted Google Takeout directory |
| `--album-recreate` | `bool` | `false` | No | Recreate albums in Proton Photos |
| `--resume` | `bool` | `false` | No | Skip completed files and retry failed ones |
| `--state-dir` | `string` | `~/.gphoto2proton/state` | No | Directory for the SQLite state database |

**Examples:**

```bash
# Basic sync
gphoto2proton sync --takeout-dir ~/Takeout/Takeout

# With album recreation
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --album-recreate

# Resume a previous run
gphoto2proton sync --takeout-dir ~/Takeout/Takeout --resume

# Custom state directory
gphoto2proton sync \
  --takeout-dir ~/Takeout/Takeout \
  --state-dir /mnt/external/proton-state

# All options
gphoto2proton sync \
  --takeout-dir ~/Takeout/Takeout \
  --album-recreate \
  --resume \
  --state-dir ~/.gphoto2proton/state
```

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
