#!/usr/bin/env bash
#
# reorder-albums.sh
#
# Force a deterministic ordering of the Proton Photos album grid on the web UI
# (https://drive.proton.me/u/1/photos/albums) by bumping each album's
# lastActivityTime in the desired order.
#
# The web UI sorts albums by lastActivityTime descending (most recently active
# first). That field is updated whenever a photo is added to or removed from an
# album. Renaming does NOT update it. So the only reliable way to reorder is to
# remove + re-add a photo from each album, processing the albums in reverse
# display order: the last album processed ends up with the most recent
# lastActivityTime and is shown first.
#
# This script reads a TSV produced by generate-album-order.sh:
#   <year>\t<album name>\t<album uid>\t<cover photo uid>
# and walks it top-to-bottom (oldest first, newest last). For each album it
# removes the cover photo from the album and immediately re-adds it. The album
# membership is unchanged; only lastActivityTime moves forward. Processing
# oldest-to-newest yields the desired final order: 2026 albums appear before
# 1980s albums in the UI.
#
# Safety:
#   - If remove-photo fails, the album is skipped untouched.
#   - If remove-photo succeeds but add-photo fails, the cover photo is reported
#     as lost from that album so it can be restored manually.
#   - Albums without a cover photo (empty albums) are skipped.
#   - --dry-run only prints what would be done.
#   - An interrupt-safe state file records completed albums so the run can be
#     resumed (or safely re-run) after a crash.
#
# Platform: Linux (GNU date/coreutils). Depends on: proton-drive CLI (auth), jq.
#
# Usage:
#   reorder-albums.sh --file album-order.tsv [--dry-run] [--yes]
#
# Options:
#   -f, --file FILE     TSV input file (year<TAB>name<TAB>uid<TAB>coverPhotoUid)
#   -n, --dry-run       Read-only: show the order and what would be done
#   -y, --yes           Skip the confirmation prompt
#   --delay SECONDS     Seconds to sleep between albums so lastActivityTime
#                       timestamps are distinct (default: 2)
#   -h, --help          Show this help
#
# Environment:
#   CLI                 proton-drive
#   LOG_DIR             $HOME/gphoto2proton/logs
#   PROTON_DRIVE_CREDENTIALS_STORE   pass
#
# Examples:
#   ./reorder-albums.sh --file album-order.tsv --dry-run
#   ./reorder-albums.sh --file album-order.tsv --yes
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

INPUT_FILE=""
MODE_DRY_RUN=0
MODE_YES=0
DELAY=2

err() { echo "ERROR: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //; s/^#$//'
  exit 0
}

while (( $# > 0 )); do
  case "$1" in
    -f|--file)  shift; INPUT_FILE="${1:-}"; [[ -z "$INPUT_FILE" ]] && { err "--file requires a path"; usage; } ;;
    -n|--dry-run) MODE_DRY_RUN=1 ;;
    -y|--yes)   MODE_YES=1 ;;
    --delay)    shift; DELAY="${1:-2}"; [[ -z "$DELAY" ]] && DELAY=2 ;;
    -h|--help)  usage ;;
    *)          err "unknown option: $1"; usage ;;
  esac
  shift
done

[[ -n "$INPUT_FILE" ]] || { err "--file is required"; usage; }
[[ -f "$INPUT_FILE" ]] || { err "input file not found: $INPUT_FILE"; exit 1; }

mkdir -p "$LOG_DIR"
run_ts=$(date +%Y%m%d-%H%M%S)
run_log="$LOG_DIR/reorder-albums-$run_ts.log"
state_base=$(basename "$INPUT_FILE")
state_file="$LOG_DIR/reorder-albums-${state_base}.done"
touch "$state_file"

# ---------------------------------------------------------------------------
# Read the TSV: year, album name, album uid, cover photo uid.
# ---------------------------------------------------------------------------
declare -a years=() names=() uids=() covers=()
while IFS=$'\t' read -r year aname auid cover; do
  [[ -z "$aname" || -z "$auid" ]] && continue
  if [[ -z "$cover" || "$cover" == "null" ]]; then
    warn "skipping \"$aname\" (no cover photo)"
    continue
  fi
  years+=("$year")
  names+=("$aname")
  uids+=("$auid")
  covers+=("$cover")
done < "$INPUT_FILE"

total=${#names[@]}
if (( total == 0 )); then
  err "no albums to process in $INPUT_FILE"
  exit 1
fi

log "reorder-albums: $total albums, oldest first, delay=${DELAY}s, log=$run_log"
if (( MODE_DRY_RUN )); then
  log "DRY-RUN — no changes will be made."
fi

for (( i = 0; i < total; i++ )); do
  printf '  %3d  %s  %s\n' "$((i+1))" "${years[$i]}" "${names[$i]}"
done

if (( ! MODE_DRY_RUN )); then
  log "this will remove+re-add the cover photo of each album above, oldest first."
  if (( ! MODE_YES )); then
    read -r -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { log "cancelled"; exit 0; }
  fi
fi

# ---------------------------------------------------------------------------
# Process each album in file order (oldest first, newest last).
# ---------------------------------------------------------------------------
processed=0 skipped=0 failed=0

for (( i = 0; i < total; i++ )); do
  year="${years[$i]}"; aname="${names[$i]}"; auid="${uids[$i]}"; cover="${covers[$i]}"

  # Skip albums already processed in a previous interrupted run.
  if (( ! MODE_DRY_RUN )) && grep -F -q "$auid" "$state_file"; then
    log "  [$((i+1))/$total] \"$aname\" already done — skipping"
    processed=$((processed + 1))
    continue
  fi

  log "  [$((i+1))/$total] \"$aname\" (year $year) ..."
  if (( MODE_DRY_RUN )); then
    log "    would remove+re-add cover $cover"
    continue
  fi

  album_path="/albums/$auid"
  photo_path="/photos/$cover"

  if ! "$CLI" album remove-photo "$album_path" "$photo_path" >"$run_log.rm.$i" 2>&1; then
    warn "    remove-photo FAILED for \"$aname\" — skipping (rc=$?)"
    failed=$((failed + 1))
    continue
  fi

  if ! "$CLI" album add-photo "$album_path" "$photo_path" >"$run_log.add.$i" 2>&1; then
    err "    remove-photo OK but add-photo FAILED for \"$aname\" — cover photo may be missing from this album! (rc=$?)"
    failed=$((failed + 1))
    continue
  fi

  echo "$auid" >> "$state_file"
  processed=$((processed + 1))

  if (( i + 1 < total && DELAY > 0 )); then
    sleep "$DELAY"
  fi
done

if (( MODE_DRY_RUN )); then
  log "==== done (dry-run): $total albums listed, nothing changed ===="
else
  log "==== done: $processed processed, $skipped skipped, $failed failed (state: $state_file) ===="
  if (( failed > 0 )); then
    err "$failed album(s) had errors — check the log and state file"
    exit 1
  fi
  log "check https://drive.proton.me/u/1/photos/albums — albums should now be newest-first"
fi
