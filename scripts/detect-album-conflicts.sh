#!/usr/bin/env bash
#
# detect-album-conflicts.sh
#
# Scan all Proton Photos albums and detect photos/videos whose capture time
# does NOT match the album's expected date range. This typically affects
# videos (.MP4, .MOV) whose EXIF was missing at upload time, causing
# proton-drive to fall back to the upload timestamp instead of the original
# recording date.
#
# Outputs a TSV file ready for fix-photo-date.sh, plus a human-readable
# summary and (optionally) a JSON report.
#
# Platform: Linux (GNU date/coreutils). Depends on: proton-drive CLI (auth), jq.
#
# Usage:
#   detect-album-conflicts.sh [options]
#
# Options:
#   --fix-tsv FILE       Output a TSV ready for fix-photo-date.sh (filename,date)
#   -n, --dry-run        Read-only: scan and report, do not write fix TSV
#   -v, --verbose        List each conflicting file per album
#   --summary-only       Just show per-album conflict counts (no details)
#   --json               Output results as JSON (machine-readable)
#   --cache-dir DIR      Cache album photo JSONs in DIR for offline reuse on
#                        subsequent runs (only album list fetched live when
#                        cache is populated)
#   --year YYYY          Only check albums with this leading year
#   --min-year YYYY      Only check albums with year >= this (skip older)
#   --max-conflict PCT   If conflict % exceeds this, warn about album-wide issue
#                        (default: 20, meaning >20% conflicts flags a warning)
#   -h, --help           Show this help
#
# Environment:
#   CLI                 proton-drive
#   LOG_DIR             $HOME/gphoto2proton/logs
#   PROTON_DRIVE_CREDENTIALS_STORE   pass
#
# Examples:
#   ./detect-album-conflicts.sh                              # Scan all albums
#   ./detect-album-conflicts.sh --summary-only                # Just conflict counts
#   ./detect-album-conflicts.sh --fix-tsv fixes.tsv           # Generate fix file
#   ./detect-album-conflicts.sh -v --year 2025                # Detailed for 2025
#   ./detect-album-conflicts.sh --cache-dir ~/photo-cache     # Cache + scan (first run)
#   ./detect-album-conflicts.sh --cache-dir ~/photo-cache     # Offline scan (subsequent)
#   ./detect-album-conflicts.sh --json > report.json          # Machine-readable
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

MODE_VERBOSE=0
MODE_SUMMARY=0
MODE_JSON=0
MODE_DRY_RUN=0
FIX_TSV=""
CACHE_DIR=""
YEAR_FILTER=""
MIN_YEAR=""
MAX_CONFLICT_PCT=20

err() { echo "ERROR: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //; s/^#$//'
  exit 0
}

while (( $# > 0 )); do
  case "$1" in
    --fix-tsv)       shift; FIX_TSV="${1:-}"; [[ -z "$FIX_TSV" ]] && { err "--fix-tsv requires a path"; usage; } ;;
    -n|--dry-run)    MODE_DRY_RUN=1 ;;
    -v|--verbose)    MODE_VERBOSE=1 ;;
    --summary-only)  MODE_SUMMARY=1 ;;
    --json)          MODE_JSON=1 ;;
    --cache-dir)     shift; CACHE_DIR="${1:-}"; [[ -z "$CACHE_DIR" ]] && { err "--cache-dir requires a path"; usage; } ;;
    --year)          shift; YEAR_FILTER="${1:-}"; [[ -z "$YEAR_FILTER" ]] && { err "--year requires YYYY"; usage; } ;;
    --min-year)      shift; MIN_YEAR="${1:-}"; [[ -z "$MIN_YEAR" ]] && { err "--min-year requires YYYY"; usage; } ;;
    --max-conflict)  shift; MAX_CONFLICT_PCT="${1:-20}" ;;
    -h|--help)       usage ;;
    *)               err "unknown option: $1"; usage ;;
  esac
  shift
done

if ! "$CLI" album list --json >/dev/null 2>/dev/null; then
  err "proton-drive is not authenticated. Run: $CLI auth login"
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract the leading year from an album name.
# Tries: leading YYYY, then embedded YYYY, then empty.
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
# Infer the most likely year from photo captureTimes in an album.
# Called when the album name has no year. Returns the most common year
# among photos that have a valid captureTime, or empty if none found.
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
# Build a default target date for videos with wrong captureTime.
# Infers month+day from the album name where possible.
# ---------------------------------------------------------------------------
default_video_date() {
  local year="$1" name="$2"
  local month="07" day="15"
  local lower
  lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

  # Helper: check if $lower contains $1 as a whole word (not substring)
  has_word() { [[ "$lower" =~ (^|[^[:alpha:]])"$1"([^[:alpha:]]|$) ]]; }

  if   has_word gennaio || has_word january || has_word janvier;        then month="01"; day="15"
  elif has_word febbraio || has_word february || has_word fevrier || has_word février; then month="02"; day="15"
  elif has_word marzo || has_word march || has_word mars;                then month="03"; day="15"
  elif has_word aprile || has_word april || has_word avril || has_word apr; then month="04"; day="15"
  elif has_word maggio || has_word may || has_word mai;                  then month="05"; day="15"
  elif has_word giugno || has_word june || has_word juin;                then month="06"; day="15"
  elif has_word luglio || has_word july || has_word juillet;             then month="07"; day="15"
  elif has_word agosto || has_word august || has_word aout || has_word août; then month="08"; day="15"
  elif has_word settembre || has_word september || has_word septembre;    then month="09"; day="15"
  elif has_word ottobre || has_word october || has_word octobre;          then month="10"; day="15"
  elif has_word novembre || has_word november || has_word novembre;       then month="11"; day="15"
  elif has_word dicembre || has_word december || has_word decembre || has_word décembre; then month="12"; day="15"
  fi

  # If a specific day number precedes the month name, use it
  if [[ "$name" =~ ([0-9]{1,2})[[:space:]]*(Gennaio|Febbraio|Marzo|Aprile|Maggio|Giugno|Luglio|Agosto|Settembre|Ottobre|Novembre|Dicembre|January|February|March|April|May|June|July|August|September|October|November|December|Janvier|Février|Mars|Avril|Mai|Juin|Juillet|Août|Septembre|Octobre|Novembre|Décembre) ]]; then
    day=$(printf "%02d" "${BASH_REMATCH[1]}" 2>/dev/null || echo "$day")
  fi

  echo "${year}-${month}-${day} 12:00:00"
}

# ---------------------------------------------------------------------------
# Per-album detection. Populates global vars below.
# ---------------------------------------------------------------------------
declare -a CONFLICT_FILES=() CONFLICT_DATES=() CONFLICT_CURRENT=()
declare -a MISSING_CAPTURE_FILES=()
CONFLICT_COUNT=0
MISSING_CAPTURE_COUNT=0
PHOTO_TOTAL=0
ALBUM_YEAR=""

detect_album_conflicts() {
  local name="$1" uid="$2"
  local album_json="" conflict_json="" missing_json=""

  CONFLICT_FILES=(); CONFLICT_DATES=(); CONFLICT_CURRENT=()
  MISSING_CAPTURE_FILES=()
  CONFLICT_COUNT=0; MISSING_CAPTURE_COUNT=0; PHOTO_TOTAL=0; ALBUM_YEAR=""

  # Try extract year from name first — avoids fetching photos for filtered albums
  ALBUM_YEAR=$(extract_album_year "$name")
  if [[ -n "$ALBUM_YEAR" ]]; then
    [[ -n "$YEAR_FILTER" && "$ALBUM_YEAR" != "$YEAR_FILTER" ]] && return 0
    [[ -n "$MIN_YEAR" && "$ALBUM_YEAR" -lt "$MIN_YEAR" ]] && return 0
  fi

  local cache_file=""
  if [[ -n "$CACHE_DIR" ]]; then
    cache_file="$CACHE_DIR/$(echo "$uid" | sed 's/\//_/g').json"
    if [[ -f "$cache_file" ]]; then
      album_json=$(<"$cache_file")
      log "cache hit for album \"$name\""
    fi
  fi

  if [[ -z "$album_json" ]]; then
    album_json=$("$CLI" album photos -d --json "/albums/$uid" 2>/dev/null) || {
      warn "failed to fetch photos for album \"$name\""; return 1
    }
    if [[ -n "$CACHE_DIR" ]]; then
      mkdir -p "$CACHE_DIR"
      echo "$album_json" > "$cache_file"
    fi
  fi

  PHOTO_TOTAL=$(jq 'length' <<< "$album_json")

  # If no year in name, infer from majority captureTime
  if [[ -z "$ALBUM_YEAR" ]]; then
    ALBUM_YEAR=$(infer_year_from_photos "$album_json")
    if [[ -n "$ALBUM_YEAR" ]]; then
      log "inferred year=$ALBUM_YEAR for album \"$name\" from photo captureTimes"
    else
      warn "cannot determine year for album \"$name\" — skipping"
      return 0
    fi
    # Apply filters now that we have an inferred year
    [[ -n "$YEAR_FILTER" && "$ALBUM_YEAR" != "$YEAR_FILTER" ]] && return 0
    [[ -n "$MIN_YEAR" && "$ALBUM_YEAR" -lt "$MIN_YEAR" ]] && return 0
  fi

  conflict_json=$(jq -c --arg y "$ALBUM_YEAR" '
    [.[] | select(
      .photo.captureTime != null and .photo.captureTime != "" and
      (.photo.captureTime | startswith($y + "-") | not)
    ) | {name: .name.value, captureTime: .photo.captureTime}]
  ' <<< "$album_json")

  missing_json=$(jq -c '
    [.[] | select(.photo.captureTime == null or .photo.captureTime == "") | {name: .name.value}]
  ' <<< "$album_json")

  CONFLICT_COUNT=$(jq 'length' <<< "$conflict_json")
  MISSING_CAPTURE_COUNT=$(jq 'length' <<< "$missing_json")

  CONFLICT_FILES=(); CONFLICT_DATES=(); CONFLICT_CURRENT=()
  MISSING_CAPTURE_FILES=()

  if [[ -n "$FIX_TSV" || MODE_VERBOSE -eq 1 ]]; then
    while IFS=$'\t' read -r fn ct; do
      [[ -z "$fn" ]] && continue
      CONFLICT_FILES+=("$fn")
      CONFLICT_CURRENT+=("$ct")
      CONFLICT_DATES+=("$(default_video_date "$ALBUM_YEAR" "$name")")
    done < <(jq -r '.[] | "\(.name)\t\(.captureTime)"' <<< "$conflict_json")

    while IFS= read -r fn; do
      [[ -z "$fn" ]] && continue
      MISSING_CAPTURE_FILES+=("$fn")
    done < <(jq -r '.[] | .name' <<< "$missing_json")
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local albums_json run_ts run_log
  run_ts=$(date +%Y%m%d-%H%M%S)
  run_log="$LOG_DIR/detect-album-conflicts-$run_ts.log"
  mkdir -p "$LOG_DIR"

  log "detect-album-conflicts: scan started, log=$run_log"

  albums_json=$("$CLI" album list --json 2>/dev/null) || { err "album list failed"; exit 1; }

  local album_count
  album_count=$(jq 'length' <<< "$albums_json")
  log "found $album_count albums"

  local total_albums=0 total_photos=0 total_conflicts=0 total_missing_capture=0
  local -a high_conflict_albums=()
  local -a json_entries=()
  local -a fix_fns=() fix_dates=()

  while IFS=$'\t' read -r aname auid; do
    [[ -z "$aname" || -z "$auid" ]] && continue
    total_albums=$((total_albums + 1))

    detect_album_conflicts "$aname" "$auid" || { CONFLICT_COUNT=0; MISSING_CAPTURE_COUNT=0; PHOTO_TOTAL=0; CONFLICT_FILES=(); continue; }

    local this_total=$PHOTO_TOTAL this_conflicts=$CONFLICT_COUNT this_missing=$MISSING_CAPTURE_COUNT
    total_photos=$((total_photos + this_total))
    total_conflicts=$((total_conflicts + this_conflicts))
    total_missing_capture=$((total_missing_capture + this_missing))

    local conflict_pct=0
    (( this_total > 0 )) && conflict_pct=$(( this_conflicts * 100 / this_total ))

    if (( conflict_pct > MAX_CONFLICT_PCT )); then
      high_conflict_albums+=("$aname ($conflict_pct%)")
    fi

    if [[ -n "$FIX_TSV" ]]; then
      for (( idx=0; idx < ${#CONFLICT_FILES[@]}; idx++ )); do
        fix_fns+=("${CONFLICT_FILES[$idx]}")
        fix_dates+=("${CONFLICT_DATES[$idx]}")
      done
    fi

    # ---- JSON accumulate ----------------------------------------------------
    if (( MODE_JSON )); then
      local entry
      entry=$(jq -n \
        --arg name "$aname" \
        --arg year "$ALBUM_YEAR" \
        --argjson total "$this_total" \
        --argjson conflicts "$this_conflicts" \
        --argjson missing "$this_missing" \
        --argjson pct "$conflict_pct" \
        '{name: $name, year: $year, total: $total, conflicts: $conflicts, missing_capture: $missing, conflict_pct: $pct}')
      json_entries+=("$entry")
      continue
    fi

    # ---- Summary-only -------------------------------------------------------
    if (( MODE_SUMMARY )); then
      if (( this_conflicts > 0 || this_missing > 0 )); then
        printf "  %-45s year=%-4s total=%-4d conflicts=%-3d missing_capture=%-3d\n" \
          "$aname" "$ALBUM_YEAR" "$this_total" "$this_conflicts" "$this_missing"
      fi
      continue
    fi

    # ---- Full output --------------------------------------------------------
    if (( this_conflicts == 0 && this_missing == 0 )); then
      (( MODE_VERBOSE )) && printf "  [OK]  %-45s %4s photos\n" "$aname" "$this_total"
      continue
    fi

    printf "\n"
    printf "  [!!] %-45s year=%s total=%d conflicts=%d missing_capture=%d (%d%%)\n" \
      "$aname" "$ALBUM_YEAR" "$this_total" "$this_conflicts" "$this_missing" "$conflict_pct"

    if (( MODE_VERBOSE && CONFLICT_COUNT > 0 )); then
      for (( idx=0; idx < ${#CONFLICT_FILES[@]}; idx++ )); do
        printf "       %-30s captureTime=%-25s → fix: %s\n" \
          "${CONFLICT_FILES[$idx]}" "${CONFLICT_CURRENT[$idx]}" "${CONFLICT_DATES[$idx]}"
      done
    fi

    if (( MODE_VERBOSE && MISSING_CAPTURE_COUNT > 0 )); then
      for fn in "${MISSING_CAPTURE_FILES[@]}"; do
        printf "       %-30s (no captureTime)\n" "$fn"
      done
    fi

  done < <(jq -r '.[] | "\(.name.value)\t\(.uid)"' <<< "$albums_json")

  # ---- Write fix TSV --------------------------------------------------------
  if [[ -n "$FIX_TSV" ]]; then
    if (( ${#fix_fns[@]} > 0 )); then
      log "writing ${#fix_fns[@]} fix entries to $FIX_TSV"
      : > "$FIX_TSV"
      for (( idx=0; idx < ${#fix_fns[@]}; idx++ )); do
        printf "%s\t%s\n" "${fix_fns[$idx]}" "${fix_dates[$idx]}" >> "$FIX_TSV"
      done
      log "fix TSV written: $FIX_TSV"
    else
      log "no conflicts found, fix TSV not written"
      : > "$FIX_TSV"
    fi
  fi

  # ---- JSON output ----------------------------------------------------------
  if (( MODE_JSON )); then
    local json_array
    if (( ${#json_entries[@]} == 0 )); then
      json_array="[]"
    else
      json_array="["
      local sep=""
      for entry in "${json_entries[@]}"; do
        json_array+="${sep}${entry}"
        sep=","
      done
      json_array+="]"
    fi
    local -a ha_temp=("${high_conflict_albums[@]+"${high_conflict_albums[@]}"}")
    local ha_json
    if (( ${#ha_temp[@]} == 0 )); then
      ha_json="[]"
    else
      ha_json=$(printf '%s\n' "${ha_temp[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
    fi
    jq -n \
      --argjson albums "$json_array" \
      --argjson total_albums "$total_albums" \
      --argjson total_photos "$total_photos" \
      --argjson total_conflicts "$total_conflicts" \
      --argjson total_missing_capture "$total_missing_capture" \
      --argjson high_conflict "$ha_json" \
      '{
        summary: {
          albums_checked: $total_albums,
          total_photos: $total_photos,
          total_conflicts: $total_conflicts,
          total_missing_capture: $total_missing_capture,
          high_conflict_albums: $high_conflict
        },
        albums: $albums
      }'
    return 0
  fi

  # ---- Human summary --------------------------------------------------------
  echo ""
  echo "========== SUMMARY =========="
  echo "  Albums checked:   $total_albums"
  echo "  Total photos:     $total_photos"
  echo "  Conflicts:        $total_conflicts"
  echo "  Missing capture:  $total_missing_capture"
  if (( ${#high_conflict_albums[@]} > 0 )); then
    echo ""
    echo "  High conflict (>${MAX_CONFLICT_PCT}%):"
    for ha in "${high_conflict_albums[@]}"; do
      echo "    $ha"
    done
  fi
  echo "============================="

  if [[ -n "$FIX_TSV" && ${#fix_fns[@]} -gt 0 ]]; then
    echo ""
    echo "  Fix TSV: $FIX_TSV (${#fix_fns[@]} entries)"
    echo "  Run: fix-photo-date.sh --file $FIX_TSV --yes"
  fi
}

main "$@"