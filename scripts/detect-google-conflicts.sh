#!/usr/bin/env bash
#
# detect-google-conflicts.sh
#
# Find every photo on Proton Drive whose capture time disagrees with the REAL
# capture time recorded by Google Photos for the same file.
#
# Why: photos imported from Google Photos via a Takeout archive often land on
# Proton with the wrong capture time (upload/extraction timestamp, or an EXIF
# date that Google had rewritten). The album-year heuristic in
# detect-album-conflicts.sh is only approximate; this script uses ground truth
# — the ".supplemental-metadata.json" sidecar that Google exports next to every
# original file, which contains "photoTakenTime".
#
# How it works:
#   1. A local source directory (DIR) must hold the original Google Photos
#      files (one folder per album) plus a ".sha1-index.txt" mapping
#      "<sha1>  <path>" for every file. For each sidecar, the script finds the
#      matching photo file and reads its real capture time.
#   2. The Proton timeline is fetched (or read from a cached file) to get every
#      photo's uid, name, current captureTime and content sha1.
#   3. Join by sha1 (and by filename as a fallback): whenever Proton's current
#      captureTime date differs from the Google photoTakenTime date, the photo
#      is a conflict.
#
# Output: a fix TSV ready for fix-photo-date.sh, one line per conflict:
#   <filename>\t<nodeUid>\t<real capture time "YYYY-MM-DD HH:MM:SS">
#
# Requires Linux (GNU date), jq, and the proton-drive CLI.
#
# Usage:
#   detect-google-conflicts.sh --local-source DIR [--timeline FILE] [-o FILE]
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

LOCAL_SOURCE=""
TIMELINE_FILE=""
OUTPUT=""
INDEX_FILE=""

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

usage() {
  cat <<'EOF'
Find Google-sourced photos whose Proton capture time differs from Google's
real photoTakenTime (from *.supplemental-metadata.json sidecars).

Usage:
  detect-google-conflicts.sh --local-source DIR [--timeline FILE] [-o FILE]

Options:
  -s, --local-source  DIR with original photos (required)
  -i, --index         FILE with the sha1 index (default: DIR/.sha1-index.txt)
  -t, --timeline      FILE with a pre-fetched 'photo timeline -d --json'
                      dump (skips the live fetch; speeds up repeated runs)
  -o, --output        FILE to write the fix TSV to (default: stdout)
  -h, --help          Show this help

Output TSV columns: filename<TAB>nodeUid<TAB>YYYY-MM-DD HH:MM:SS
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      -s|--local-source) shift; LOCAL_SOURCE="${1:-}"; [[ -z "$LOCAL_SOURCE" ]] && { err "--local-source requires a path"; usage; return 2; } ;;
      -i|--index) shift; INDEX_FILE="${1:-}"; [[ -z "$INDEX_FILE" ]] && { err "--index requires a file"; usage; return 2; } ;;
      -t|--timeline) shift; TIMELINE_FILE="${1:-}"; [[ -z "$TIMELINE_FILE" ]] && { err "--timeline requires a file"; usage; return 2; } ;;
      -o|--output) shift; OUTPUT="${1:-}"; [[ -z "$OUTPUT" ]] && { err "--output requires a file"; usage; return 2; } ;;
      *) err "unknown: $1"; usage; return 2 ;;
    esac
    shift
  done

  if [[ -z "$LOCAL_SOURCE" ]]; then err "--local-source is required"; usage; return 2; fi
  if [[ ! -d "$LOCAL_SOURCE" ]]; then err "local source dir not found: $LOCAL_SOURCE"; return 2; fi
  local index="${INDEX_FILE:-$LOCAL_SOURCE/.sha1-index.txt}"
  if [[ ! -f "$index" ]]; then
    err "missing $index (build it case-insensitively, e.g.:"
    err "  find \"$LOCAL_SOURCE\" -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.nef' \\) -exec sha1sum {} + > \"$index\")"
    return 2
  fi

  local missing=()
  local b
  for b in "$CLI" jq date find awk sort cut; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then err "missing: ${missing[*]}"; return 1; fi

  mkdir -p "$LOG_DIR"
  local work="$LOG_DIR/detect-google-conflicts-work-$$"
  mkdir -p "$work"
  trap '[[ -n "${work:-}" ]] && rm -rf "$work"' EXIT

  # ------------------------------------------------------------------
  # 1) Build the local map: sha1 → (real epoch, basename).
  #    Efficient: one find + one batched jq for all sidecars, one awk join
  #    against the sha1 index.
  # ------------------------------------------------------------------
  log "building local real-capture-time map from $LOCAL_SOURCE ..."

  # Extract photoTakenTime from every sidecar in one batched jq pass.
  # jq emits one TSV line "sidecar_path<TAB>epoch" per file via input_filename.
  local sidecars_tsv="$work/sidecars.tsv"
  find "$LOCAL_SOURCE" -name '*.supplemental-metadata.json' -print0 \
    | xargs -0 jq -r '[input_filename, (.photoTakenTime.timestamp // empty)] | @tsv' 2>/dev/null \
    > "$sidecars_tsv" || true

  # Join: sidecar path → photo path → sha1 (from index, field 2 = path).
  # Emit "sha1<TAB>epoch<TAB>basename". Duplicate sha1 across albums are fine
  # (same file, same date) — last one wins.
  local local_map="$work/local-map.tsv"
  # sha1sum emits "HASH  PATH" (two spaces); paths may contain spaces, so split
  # on the first two-space separator instead of relying on field splitting.
  awk -F'\t' '
    function norm(p) { sub(/^\.\//, "", p); return p }
    NR==FNR {
      p = index($0, "  ")
      if (p > 1) path_sha1[norm(substr($0, p+2))] = substr($0, 1, p-1)
      next
    }
    {
      photo=$1; sub(/\.supplemental-metadata\.json$/, "", photo)
      photo = norm(photo)
      if (photo in path_sha1) {
        n=split(photo, parts, "/"); bn=parts[n]
        print path_sha1[photo] "\t" $2 "\t" bn
      }
    }
  ' "$index" "$sidecars_tsv" | sort -u > "$local_map"
  local n_local
  n_local=$(wc -l < "$local_map")
  log "  $n_local local photos with a Google capture time"

  # ------------------------------------------------------------------
  # 2) Fetch (or read) the Proton timeline.
  # ------------------------------------------------------------------
  local timeline="$work/timeline.json"
  if [[ -n "$TIMELINE_FILE" ]]; then
    if [[ ! -f "$TIMELINE_FILE" ]]; then err "timeline file not found: $TIMELINE_FILE"; return 2; fi
    cp "$TIMELINE_FILE" "$timeline"
    log "reading timeline from $TIMELINE_FILE"
  else
    log "fetching Proton timeline (this takes ~1 min) ..."
    if ! "$CLI" photo timeline -d --json > "$timeline" 2>/dev/null; then
      err "timeline fetch failed"; return 1
    fi
  fi

  # timeline → sha1<TAB>uid<TAB>name<TAB>captureTime
  local timeline_tsv="$work/timeline.tsv"
  jq -r '.[] | [(.activeRevision.claimedDigests.sha1 // ""), .uid, (.name.value // ""), (.photo.captureTime // "")] | @tsv' "$timeline" 2>/dev/null > "$timeline_tsv"
  local n_tl
  n_tl=$(wc -l < "$timeline_tsv")
  log "  $n_tl photos in Proton timeline"

  # ------------------------------------------------------------------
  # 3) Compare. Prefer sha1 match; fall back to unique filename match
  #    (covers files whose bytes differ, e.g. NEF converted to JPG).
  # ------------------------------------------------------------------
  declare -A local_ts=() local_name=()
  local s t bn
  while IFS=$'\t' read -r s t bn; do
    local_ts["$s"]="$t"
    local_name["$s"]="$bn"
  done < "$local_map"

  # basename → epoch for the filename fallback (last wins; duplicates rare)
  declare -A local_by_name=()
  while IFS=$'\t' read -r s t bn; do
    [[ -n "$bn" ]] && local_by_name["$bn"]="$t"
  done < "$local_map"

  # count name occurrences in the timeline (only flag unique names by fallback)
  local name_count="$work/name-count.tsv"
  cut -f3 "$timeline_tsv" | sort | uniq -c | awk '{print $2"\t"$1}' > "$name_count"
  declare -A tl_name_count=()
  local nm c
  while IFS=$'\t' read -r nm c; do
    tl_name_count["$nm"]="$c"
  done < "$name_count"

  local conflicts="$work/conflicts.tsv"
  : > "$conflicts"
  local sha1 uid name cap real_utc cap_date out_date real_epoch n_sha1_matches n_checked=0 n_conflicts=0

  while IFS=$'\t' read -r sha1 uid name cap; do
    [[ -z "$sha1" ]] && continue
    n_checked=$((n_checked + 1))

    real_epoch=""
    if [[ -n "${local_ts[$sha1]:-}" ]]; then
      real_epoch="${local_ts[$sha1]}"
    elif [[ -n "$name" && "${tl_name_count[$name]:-0}" == "1" && -n "${local_by_name[$name]:-}" ]]; then
      real_epoch="${local_by_name[$name]}"
    fi
    [[ -z "$real_epoch" ]] && continue

    real_utc=$(date -u -d "@$real_epoch" '+%Y-%m-%d' 2>/dev/null || true)
    cap_date="${cap:0:10}"
    [[ -z "$real_utc" || -z "$cap_date" ]] && continue

    if [[ "$real_utc" != "$cap_date" ]]; then
      out_date=$(date -d "@$real_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)
      [[ -z "$out_date" ]] && continue
      printf '%s\t%s\t%s\n' "$name" "$uid" "$out_date" >> "$conflicts"
      n_conflicts=$((n_conflicts + 1))
    fi
  done < "$timeline_tsv"

  log "  compared $n_checked timeline photos (those with a sha1)"
  log "  CONFLICTS FOUND: $n_conflicts (Proton date differs from Google photoTakenTime)"

  if [[ -n "$OUTPUT" ]]; then
    if [[ -s "$conflicts" ]]; then
      cp "$conflicts" "$OUTPUT"
      log "fix TSV written to $OUTPUT"
    else
      : > "$OUTPUT"
      log "no conflicts — wrote empty TSV to $OUTPUT"
    fi
  else
    cat "$conflicts"
  fi

  return 0
}

main "$@"
