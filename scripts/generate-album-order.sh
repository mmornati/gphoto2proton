#!/usr/bin/env bash
#
# generate-album-order.sh
#
# Generate an ordered list of all Proton Photos albums, oldest first. The order
# is derived from the album's expected year:
#   - a 4-digit year in the album name (leading or embedded) is used directly;
#   - otherwise the year is inferred from the majority captureTime of the
#     album's photos (using the --cache-dir caches from detect-album-conflicts.sh
#     when available, falling back to a live API call).
#
# The output is a TSV consumed by reorder-albums.sh:
#   <year>\t<album name>\t<album uid>\t<cover photo uid>
#
# reorder-albums.sh walks this file top-to-bottom and "touches" each album so
# its lastActivityTime ends up monotonic with the year — making the Proton web
# UI show albums chronologically (newest last-processed => shown first).
#
# Platform: Linux (GNU date/coreutils). Depends on: proton-drive CLI (auth), jq.
#
# Usage:
#   generate-album-order.sh [options]
#
# Options:
#   --cache-dir DIR      Directory with per-album JSON caches (from
#                        detect-album-conflicts.sh --cache-dir). Used to infer
#                        years for albums without one in the name, without
#                        re-fetching photos from the API.
#   --output FILE        Write the TSV to FILE instead of stdout.
#   -h, --help           Show this help
#
# Environment:
#   CLI                 proton-drive
#   PROTON_DRIVE_CREDENTIALS_STORE   pass
#
# Examples:
#   ./generate-album-order.sh --cache-dir photo-cache --output album-order.tsv
#   ./generate-album-order.sh > album-order.tsv
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

CACHE_DIR=""
OUTPUT_FILE=""

err() { echo "ERROR: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //; s/^#$//'
  exit 0
}

while (( $# > 0 )); do
  case "$1" in
    --cache-dir)   shift; CACHE_DIR="${1:-}"; [[ -z "$CACHE_DIR" ]] && { err "--cache-dir requires a path"; usage; } ;;
    --output)      shift; OUTPUT_FILE="${1:-}"; [[ -z "$OUTPUT_FILE" ]] && { err "--output requires a path"; usage; } ;;
    -h|--help)     usage ;;
    *)             err "unknown option: $1"; usage ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Extract a year from an album name: leading YYYY, then embedded YYYY, else "".
# ---------------------------------------------------------------------------
extract_album_year() {
  local name="$1"
  if [[ "$name" =~ ^[[:space:]]*([0-9]{4}) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ([0-9]{4}) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Infer the most common year from an album-photos JSON array.
# ---------------------------------------------------------------------------
infer_year_from_photos() {
  local album_json="$1"
  jq -r '
    [.[] | .photo.captureTime | select(. != null and . != "") | .[0:4]]
    | group_by(.)
    | map({year: .[0], count: length})
    | sort_by(-.count)
    | .[0].year // empty
  ' <<< "$album_json"
}

# ---------------------------------------------------------------------------
# Resolve the year for one album: name first, then cache, then live API.
# Prints the year, or empty if it cannot be determined.
# ---------------------------------------------------------------------------
resolve_album_year() {
  local name="$1" uid="$2" year=""
  year=$(extract_album_year "$name")
  if [[ -n "$year" ]]; then
    echo "$year"; return 0
  fi

  # No year in name — try the cache dir from detect-album-conflicts.sh.
  if [[ -n "$CACHE_DIR" && -d "$CACHE_DIR" ]]; then
    local cache_file
    cache_file="$CACHE_DIR/$(echo "$uid" | sed 's/\//_/g').json"
    if [[ -f "$cache_file" ]]; then
      year=$(infer_year_from_photos "$(cat "$cache_file")")
      if [[ -n "$year" ]]; then
        log "inferred year=$year for \"$name\" from cache"
        echo "$year"; return 0
      fi
    fi
  fi

  # Fall back to a live API call for the album photos.
  local album_json
  if album_json=$("$CLI" album photos -d --json "/albums/$uid" 2>/dev/null); then
    year=$(infer_year_from_photos "$album_json")
    if [[ -n "$year" ]]; then
      log "inferred year=$year for \"$name\" from live API"
      echo "$year"; return 0
    fi
  fi

  echo ""
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "generate-album-order: fetch album list ..."

albums_json=$("$CLI" album list --json 2>/dev/null) || { err "album list failed"; exit 1; }

album_count=$(jq 'length' <<< "$albums_json")
log "found $album_count albums"

declare -a out_rows=()
unknown_count=0

while IFS=$'\t' read -r aname auid cover_puid; do
  [[ -z "$aname" || -z "$auid" ]] && continue

  # Albums with no photos (or no cover) cannot be "touched" by reorder-albums.sh.
  if [[ -z "$cover_puid" || "$cover_puid" == "null" ]]; then
    warn "skipping \"$aname\" (no cover photo / empty album)"
    continue
  fi

  year=$(resolve_album_year "$aname" "$auid")
  if [[ -z "$year" ]]; then
    warn "cannot determine year for \"$aname\" — sorting last (year=9999)"
    year="9999"
    unknown_count=$((unknown_count + 1))
  fi

  out_rows+=("$year"$'\t'"$aname"$'\t'"$auid"$'\t'"$cover_puid")
done < <(jq -r '.[] | [.name.value, .uid, .album.coverPhotoNodeUid] | @tsv' <<< "$albums_json")

# Sort by year ascending, then by name, then write to stdout or --output.
# The array entries already contain literal tab separators.
if (( ${#out_rows[@]} > 0 )); then
  if [[ -n "$OUTPUT_FILE" ]]; then
    printf '%s\n' "${out_rows[@]}" | sort -t $'\t' -k1,1n -k2,2 > "$OUTPUT_FILE"
    log "wrote $(wc -l < "$OUTPUT_FILE") albums to $OUTPUT_FILE"
  else
    printf '%s\n' "${out_rows[@]}" | sort -t $'\t' -k1,1n -k2,2
  fi
else
  warn "no albums to emit"
fi

if (( unknown_count > 0 )); then
  warn "$unknown_count album(s) had no determinable year and were sorted last (year=9999)"
fi
