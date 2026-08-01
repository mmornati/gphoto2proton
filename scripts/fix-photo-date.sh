#!/usr/bin/env bash
#
# fix-photo-date.sh
#
# Fix the capture time of already-uploaded Proton Photos that have the wrong
# date (typically videos whose takeout sidecar was missing, so the CLI fell
# back to the archive extraction timestamp instead of the original recording
# date).
#
# The script downloads each photo, adjusts its filesystem mtime, re-uploads it
# to Proton (capturing the correct capture time from the adjusted mtime), and
# restores album membership.
#
# Input: a TSV file with two columns per line:
#   <filename>\t<date_or_timestamp>
#
# Supported date formats:
#   Unix epoch seconds    1476540000
#   ISO datetime          2016-10-15 16:37:23  or  2016-10-15T16:37:23
#   Compact               20161015 163723
#   Date only             2016-10-15           (time defaults to 12:00:00)
#
# Usage:
#   fix-photo-date.sh --file fixes.tsv [--dry-run] [--yes]
#
# Options:
#   -f, --file  TSV input file (required)
#   -n, --dry-run  Read-only: show what would be fixed, don't execute
#   -y, --yes   Skip confirmation prompt
#   -h, --help  Show this help
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

RUN_TS=""
RUN_LOG=""
DRY_RUN=0
YES=0

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" | tee -a "$RUN_LOG" >&2; }

usage() {
  cat <<'EOF'
Fix capture time of already-uploaded Proton Photos.

Usage:
  fix-photo-date.sh -f fixes.tsv [--dry-run] [--yes]

Options:
  -f, --file   TSV input file (filename<TAB>date)
  -n, --dry-run  Read-only: show what would be done
  -y, --yes    Skip confirmation prompt
  -h, --help   Show this help
EOF
}

# ---------------------------------------------------------------------------
# Date conversion: parse various formats → touch -t compatible string
# Uses GNU date's flexible parsing; epoch seconds handled specially.
# ---------------------------------------------------------------------------
to_touch_format() {
  local input="$1" fmt

  # Strip whitespace
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"

  # Unix epoch seconds (all digits)
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    fmt=$(date -d "@$input" +%Y%m%d%H%M.%S 2>/dev/null) || return 1
    echo "$fmt"
    return 0
  fi

  fmt=$(date -d "$input" +%Y%m%d%H%M.%S 2>/dev/null) && { echo "$fmt"; return 0; }
  return 1
}

format_date_human() {
  local input="$1"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    date -d "@$input" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$input"
  else
    date -d "$input" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$input"
  fi
}

# ---------------------------------------------------------------------------
# Parse timeline JSON → filename→{uid, albums} mapping
# ---------------------------------------------------------------------------
extract_photo_info() {
  local timeline_json="$1" filename="$2"
  jq -r --arg f "$filename" '
    .[] | select(.name.value == $f) |
    "\(.uid)\t\(.photo.albums | join(","))"
  ' "$timeline_json" | head -1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  local missing=()
  for b in "$CLI" jq date; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then err "missing: ${missing[*]}"; return 1; fi
  if ! "$CLI" album list --json >/dev/null 2>/dev/null; then
    err "CLI not authenticated"; return 1
  fi
  log "CLI=$CLI auth OK (store=$PROTON_DRIVE_CREDENTIALS_STORE)"
  mkdir -p "$LOG_DIR"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      -f|--file) shift; file="${1:-}"; [[ -z "$file" ]] && { err "--file requires a value"; usage; return 2; } ;;
      -n|--dry-run) DRY_RUN=1 ;;
      -y|--yes) YES=1 ;;
      *) err "unknown: $1"; usage; return 2 ;;
    esac
    shift
  done

  if [[ -z "$file" ]]; then err "--file is required"; usage; return 2; fi
  if [[ ! -f "$file" ]]; then err "file not found: $file"; return 2; fi

  RUN_TS=$(date +%Y%m%d-%H%M%S)
  RUN_LOG="$LOG_DIR/fix-photo-date-$RUN_TS.log"
  touch "$RUN_LOG"

  log "fix-photo-date: file=$file log=$RUN_LOG"
  preflight || return 1

  # Read entries into arrays.
  local -a filenames=() date_inputs=()
  local line_ok=0 line_num=0
  while IFS=$'\t' read -r fn dt rest; do
    line_num=$((line_num + 1))
    [[ -z "$fn" ]] && continue
    [[ -z "$dt" ]] && { err "line $line_num: missing date for \"$fn\""; continue; }
    filenames+=("$fn")
    date_inputs+=("$dt")
    line_ok=$((line_ok + 1))
  done < "$file"

  if (( ${#filenames[@]} == 0 )); then err "no valid entries in $file"; return 1; fi
  log "read ${#filenames[@]} entries from $file"

  if (( DRY_RUN == 0 && YES == 0 )); then
    echo ""
    echo "This will fix ${#filenames[@]} photo(s). Each photo will be:"
    echo "  - Downloaded from Proton"
    echo "  - Modified offline (mtime adjusted)"
    echo "  - Deleted from Proton (trash + permanent delete)"
    echo "  - Re-uploaded with the correct capture time"
    echo "  - Re-added to its original albums"
    echo ""
    read -r -p "Proceed? [y/N] " confirm
    [[ "$confirm" =~ ^[yY] ]] || { log "cancelled"; return 0; }
  fi

  local total=${#filenames[@]} fix_ok=0 fix_fail=0

  for (( i = 0; i < total; i++ )); do
    local fn="${filenames[$i]}" dt="${date_inputs[$i]}"
    local touch_fmt human_date
    touch_fmt=$(to_touch_format "$dt") || { err "cannot parse date \"$dt\" for \"$fn\""; fix_fail=$((fix_fail+1)); continue; }
    human_date=$(format_date_human "$dt")
    log "[$((i+1))/$total] ==== $fn → $human_date ===="

    # Fetch current timeline to find the photo.
    local timeline_before="$LOG_DIR/.timeline-before-$$.json"
    "$CLI" photo timeline -d --json > "$timeline_before" 2>/dev/null; local rc=$?
    if (( rc != 0 )); then err "timeline fetch failed"; fix_fail=$((fix_fail+1)); continue; fi

    local info uid
    info=$(extract_photo_info "$timeline_before" "$fn")
    uid=$(echo "$info" | cut -f1)
    local albums_csv album_uids
    albums_csv=$(echo "$info" | cut -f2)
    IFS=',' read -ra album_uids <<< "$albums_csv"

    if [[ -z "$uid" ]]; then
      err "photo \"$fn\" not found in timeline"
      fix_fail=$((fix_fail+1)); rm -f "$timeline_before"; continue
    fi
    log "  uid=$uid albums=${#album_uids[@]} (${albums_csv:-none})"

    # Capture current sha1 + creationTime to find the new upload later.
    capture_before=$(jq -r --arg u "$uid" '.[] | select(.uid == $u) | .photo.captureTime // "unknown"' "$timeline_before" | head -1)
    local sha1_before
    sha1_before=$(jq -r --arg u "$uid" '.[] | select(.uid == $u) | .activeRevision.claimedDigests.sha1 // empty' "$timeline_before" | head -1)
    log "  current captureTime: $capture_before  sha1=$sha1_before"

    if (( DRY_RUN )); then
      log "  DRY RUN: would download, fix mtime, trash, re-upload, re-add to ${#album_uids[@]} album(s)"
      rm -f "$timeline_before"
      continue
    fi

    # Download.
    local tmpdir="$LOG_DIR/.fix-$$"
    mkdir -p "$tmpdir"
    log "  downloading ..."
    if ! "$CLI" photo download "/photos/$uid" "$tmpdir" > "$tmpdir/download.out" 2>&1; then
      err "download failed for $fn"; rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi

    local local_path="$tmpdir/$fn"
    if [[ ! -f "$local_path" ]]; then
      # filename may differ (case, encoding) — find it.
      local_path=$(find "$tmpdir" -type f -print | head -1)
    fi
    if [[ ! -f "$local_path" ]]; then
      err "downloaded file not found for $fn"; rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi

    # Fix mtime.
    log "  setting mtime to $human_date ($touch_fmt)"
    if ! touch -t "$touch_fmt" "$local_path"; then
      err "touch failed for $fn"; rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi

    # Trash old.
    log "  trashing old uid=$uid ..."
    if ! "$CLI" trash "/photos/$uid" > "$tmpdir/trash.out" 2>&1; then
      err "trash failed for $fn"; rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi

    # Delete from trash.
    log "  permanently deleting ..."
    if ! "$CLI" delete "/photos-trash/$uid" > "$tmpdir/delete.out" 2>&1; then
      err "delete from trash failed for $fn"; rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi

    # Re-upload with keep-both (forces a new upload even if the old photo
    # is still visible in a stale dedup cache; the old copy is already deleted).
    log "  re-uploading (keep-both) ..."
    local upload_json="$tmpdir/upload.json"
    if ! "$CLI" photo upload --json -c keep-both "$local_path" > "$upload_json" 2>"$tmpdir/upload.err"; then
      local upload_rc=$?
      local transferred
      transferred=$(jq '.transferredItems // 0' "$upload_json" 2>/dev/null || echo 0)
      if (( transferred == 0 )); then
        err "upload failed (rc=$upload_rc, transferred=0) for $fn"
      fi
      rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi
    local transferred
    transferred=$(jq '.transferredItems // 0' "$upload_json")
    if (( transferred == 0 )); then
      err "upload transferred 0 items for $fn (dedup despite keep-both)"
      rm -rf "$tmpdir" "$timeline_before"; fix_fail=$((fix_fail+1)); continue
    fi

    # Find the new uid by matching content sha1 (same file content, same hash).
    local timeline_after="$LOG_DIR/.timeline-after-$$.json"
    sleep 2  # brief cooldown for event propagation
    "$CLI" photo timeline -d --json > "$timeline_after" 2>/dev/null || true
    local new_uid
    new_uid=$(jq -r --arg s "$sha1_before" '
      [.[] | select(.activeRevision.claimedDigests.sha1 == $s)] | sort_by(.creationTime) | last | .uid // empty
    ' "$timeline_after")
    if [[ -z "$new_uid" ]]; then
      err "new uid not found for $fn after re-upload"
      rm -rf "$tmpdir" "$timeline_before" "$timeline_after"
      fix_fail=$((fix_fail+1)); continue
    fi
    log "  new uid=$new_uid"

    # Re-add to albums.
    if (( ${#album_uids[@]} > 0 )); then
      local album_uid
      for album_uid in "${album_uids[@]}"; do
        [[ -z "$album_uid" ]] && continue
        log "  adding to album $album_uid ..."
        if ! "$CLI" album add-photo "/albums/$album_uid" "/photos/$new_uid" > "$tmpdir/album-add-$album_uid.out" 2>&1; then
          err "album add-photo failed for $album_uid (photo $new_uid)"
        else
          log "    done"
        fi
      done
    fi

    # Cleanup.
    rm -rf "$tmpdir" "$timeline_before" "$timeline_after"
    fix_ok=$((fix_ok + 1))
    log "  OK"
  done

  log "==== done: $fix_ok fixed, $fix_fail failed ===="
  if (( fix_fail > 0 )); then
    err "$fix_fail photo(s) failed — check log: $RUN_LOG"
    return 1
  fi
  return 0
}

main "$@"