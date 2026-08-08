#!/usr/bin/env bash
#
# fix-photo-date.sh
#
# Fix the capture time of already-uploaded Proton Photos that have the wrong
# date (typically videos whose takeout sidecar was missing, so the CLI fell
# back to the archive extraction timestamp instead of the original recording
# date).
#
# For each photo: look it up in a prefetched timeline index, download the
# original bytes, verify content (sha1), adjust the filesystem mtime, persist
# a state file, trash + permanently delete the old copy, re-upload (CLI reads
# the new mtime as the capture time for videos).
#
# Performance: instead of re-fetching the full timeline after EVERY upload to
# locate the new uid (162MB JSON per photo), the fix phase runs for all photos
# first, then a single final timeline fetch is used to locate all new uids by
# content sha1, verify the new capture time, and restore album membership.
# A compact uid-keyed index (built once) makes all lookups near-instant.
#
# Safety: the downloaded file and a state file (uid, albums, sha1, target
# date) are kept in $LOG_DIR/fix-work-<run>/ until the photo is FULLY fixed.
# Any failure leaves them in place for manual recovery; nothing is lost.
# (The downloaded byte copy is removed right after a successful re-upload;
# the state file is retained until the batch verification succeeds.)
#
# Timezone: naive datetimes are interpreted in the SERVER's timezone (the
# date matters more than the exact time here). Override with TZ=... if needed.
# Requires Linux (GNU date/coreutils).
#
# Input: a TSV file with two or three columns per line:
#   <filename>\t<date_or_timestamp>
#   <filename>\t<nodeUid>\t<date_or_timestamp>   (uid-pinned, unambiguous)
#
# Supported date formats:
#   Unix epoch seconds    1476540000        (9-11 digits)
#   ISO datetime          2016-10-15 16:37:23  or  2016-10-15T16:37:23
#   Compact datetime      20161015 163723   (date + time separated by space)
#   Compact               20161015          (time defaults to 12:00:00)
#   Date only             2016-10-15        (time defaults to 12:00:00)
#
# Usage:
#   fix-photo-date.sh --file fixes.tsv [--album-cache DIR] [--local-source DIR]
#                     [--index FILE] [--exif-date] [--dry-run] [--yes]
#
# The --album-cache DIR option points at the per-album JSON cache produced by
# detect-album-conflicts.sh. The timeline's photo.albums field is often empty,
# so album membership is recovered from these cache files instead. DIR should
# contain one <album-uid>.json file per album.
#
# The --local-source DIR option points at a directory containing the original
# Google Photos files (e.g. extracted from a Takeout archive, one folder per
# album). Its .sha1-index.txt (or the file given with --index) must map
# "<sha1>  <path>" for every file. Photos
# found locally by sha1 are copied from disk instead of downloaded from Proton
# (much faster), and a sibling ".supplemental-metadata.json" file is used to
# override the target date with the REAL Google capture time (photoTakenTime)
# when available.
#
# The --exif-date flag additionally rewrites the EXIF date tags
# (DateTimeOriginal / CreateDate / ModifyDate) of the local copy before upload.
# JPEGs without a usable EXIF date keep the filesystem mtime as the capture
# time; rewriting the EXIF tags makes Proton honour the corrected date for
# image files too (requires exiftool; other metadata like GPS is preserved).
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

RUN_TS=""
RUN_LOG="/dev/null"
WORK_DIR=""
DRY_RUN=0
YES=0
ALBUM_CACHE=""
LOCAL_SOURCE=""
INDEX_FILE=""
EXIF_DATE=0

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" | tee -a "$RUN_LOG" >&2; }

usage() {
  cat <<'EOF'
Fix capture time of already-uploaded Proton Photos (Linux, proton-drive CLI).

Usage:
  fix-photo-date.sh -f fixes.tsv [--dry-run] [--yes]

Options:
  -f, --file         TSV input file (filename<TAB>date or filename<TAB>nodeUid<TAB>date) — required
  -a, --album-cache  DIR with per-album JSON cache (from detect-album-conflicts.sh)
                     used to recover album membership when the timeline lacks it
  -s, --local-source DIR with extracted original photos + .sha1-index.txt;
                     use local copies instead of downloading, and prefer the
                     real capture time from *.supplemental-metadata.json
  -i, --index FILE   Path to the sha1 index (default DIR/.sha1-index.txt);
                     useful when the local-source dir is read-only
  -x, --exif-date    Rewrite EXIF date tags (DateTimeOriginal/CreateDate/
                     ModifyDate) of the fixed copy before upload (exiftool).
                     Preserves all other EXIF metadata (GPS, camera, ...).
  -n, --dry-run      Read-only: show what would be done
  -y, --yes          Skip confirmation prompt
  -h, --help         Show this help

Naive datetimes use the server's timezone; set TZ=... to override.
EOF
}

# ---------------------------------------------------------------------------
# Interrupt handling: never silently lose a downloaded photo or its state.
# ---------------------------------------------------------------------------
on_interrupt() {
  err "interrupted — preserved downloads/state in: $WORK_DIR"
  exit 130
}

# ---------------------------------------------------------------------------
# Date conversion helpers (GNU date). Echo result; rc!=0 on failure.
# ---------------------------------------------------------------------------
to_epoch() {
  local input="$1"
  date -d "$input" +%s 2>/dev/null
}

to_touch_format() {
  local input="$1"
  date -d "$input" +%Y%m%d%H%M.%S 2>/dev/null
}

# Normalize any supported input to "YYYY-MM-DD HH:MM:SS" (echo) or rc=1.
normalize_date() {
  local input="$1"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  [[ -z "$input" ]] && return 1

  # Compact datetime "YYYYMMDD HHMMSS" (documented space-separated form)
  if [[ "$input" =~ ^([0-9]{8})[[:space:]]+([0-9]{6})$ ]]; then
    local d8="${BASH_REMATCH[1]}" t6="${BASH_REMATCH[2]}"
    date -d "${d8:0:4}-${d8:4:2}-${d8:6:2} ${t6:0:2}:${t6:2:2}:${t6:4:2}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
    return
  fi

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    local len=${#input}
    case "$len" in
      8)  # YYYYMMDD → noon
        date -d "${input:0:4}-${input:4:2}-${input:6:2} 12:00:00" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
        return ;;
      14) # YYYYMMDDHHMMSS
        date -d "${input:0:4}-${input:4:2}-${input:6:2} ${input:8:2}:${input:10:2}:${input:12:2}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
        return ;;
      9|10|11) # epoch seconds, sanity range 1990-01-01 .. now+1d
        local now
        now=$(date +%s)
        if (( input < 631152000 || input > now + 86400 )); then
          return 1
        fi
        date -d "@$input" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
        return ;;
      *) return 1 ;;
    esac
  fi

  # YYYY-MM-DD alone → noon (as documented in the header)
  if [[ "$input" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    date -d "$input 12:00:00" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
    return
  fi

  date -d "$input" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  local missing=()
  local b
  for b in "$CLI" jq date sha1sum touch find awk sort cut grep; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then err "missing: ${missing[*]}"; return 1; fi
  if ! "$CLI" album list --json >/dev/null 2>/dev/null; then
    err "CLI not authenticated (store=$PROTON_DRIVE_CREDENTIALS_STORE)"; return 1
  fi
  log "CLI=$CLI auth OK (store=$PROTON_DRIVE_CREDENTIALS_STORE)"
  return 0
}

# ---------------------------------------------------------------------------
# Build a compact uid-keyed TSV index from a timeline JSON (single jq pass).
# Columns: uid<TAB>name<TAB>captureTime<TAB>sha1<TAB>albumsCsv
# ---------------------------------------------------------------------------
build_uid_index() {
  local timeline_json="$1" index_file="$2"
  jq -r '
    .[] | [
      .uid,
      (.name.value // ""),
      (.photo.captureTime // ""),
      (.activeRevision.claimedDigests.sha1 // ""),
      ((((.photo.albums // []) | map(if type == "object" then (.nodeUid // "") else . end)) | map(select(. != ""))) | join(","))
    ] | @tsv
  ' "$timeline_json" 2>/dev/null > "$index_file"
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
      -a|--album-cache) shift; ALBUM_CACHE="${1:-}"; [[ -z "$ALBUM_CACHE" ]] && { err "--album-cache requires a path"; usage; return 2; } ;;
      -s|--local-source) shift; LOCAL_SOURCE="${1:-}"; [[ -z "$LOCAL_SOURCE" ]] && { err "--local-source requires a path"; usage; return 2; } ;;
      -i|--index) shift; INDEX_FILE="${1:-}"; [[ -z "$INDEX_FILE" ]] && { err "--index requires a path"; usage; return 2; } ;;
      -x|--exif-date) EXIF_DATE=1 ;;
      *) err "unknown: $1"; usage; return 2 ;;
    esac
    shift
  done

  if [[ -z "$file" ]]; then err "--file is required"; usage; return 2; fi
  if [[ ! -f "$file" ]]; then err "file not found: $file"; return 2; fi
  if (( EXIF_DATE )); then
    if ! command -v exiftool >/dev/null 2>&1; then
      err "--exif-date requires exiftool (not found in PATH)"; return 2
    fi
    log "exif-date mode: EXIF date tags will be rewritten (exiftool found)"
  fi
  if [[ -n "$LOCAL_SOURCE" ]]; then
    if [[ ! -d "$LOCAL_SOURCE" ]]; then err "local source dir not found: $LOCAL_SOURCE"; return 2; fi
    INDEX_FILE="${INDEX_FILE:-$LOCAL_SOURCE/.sha1-index.txt}"
    if [[ ! -f "$INDEX_FILE" ]]; then
      err "local source missing $INDEX_FILE (build it with: find ... -exec sha1sum {} + > .sha1-index.txt)"; return 2
    fi
  fi

  mkdir -p "$LOG_DIR"
  RUN_TS=$(date +%Y%m%d-%H%M%S)
  RUN_LOG="$LOG_DIR/fix-photo-date-$RUN_TS.log"
  WORK_DIR="$LOG_DIR/fix-work-$RUN_TS"
  touch "$RUN_LOG"
  trap on_interrupt INT TERM
  mkdir -p "$WORK_DIR"

  log "fix-photo-date: file=$file log=$RUN_LOG work=$WORK_DIR"
  preflight || return 1

  # --- Read TSV (trim names, strip CR, dedupe, tolerate missing trailing \n).
  # Three-column format: filename\tnodeUid\tdate
  # (nodeUid optional — 2-column format still accepted for backward compat)
  local -a filenames=() date_inputs=() file_uids=()
  local line_num=0 fn col2 col3 rest
  declare -A seen_names=()
  while IFS=$'\t' read -r fn col2 col3 rest || [[ -n "${fn:-}" ]]; do
    line_num=$((line_num + 1))
    fn="${fn%$'\r'}"
    fn="${fn#"${fn%%[![:space:]]*}"}"
    fn="${fn%"${fn##*[![:space:]]}"}"
    [[ -z "$fn" ]] && continue
    if [[ -n "${seen_names[$fn]:-}" ]]; then
      err "line $line_num: duplicate entry for \"$fn\" — keeping first, skipping"
      continue
    fi
    seen_names[$fn]=1
    if [[ -z "$col2" ]]; then
      err "line $line_num: missing data for \"$fn\" — skipping"
      continue
    fi
    # Detect 3-col format: filename\tnodeUid\tdate
    # nodeUid contains ~, date contains -
    local uid_col="" dt
    if [[ -n "$col3" && "$col2" == *"~"* ]]; then
      uid_col="$col2"
      dt="$col3"
    else
      dt="$col2"
    fi
    filenames+=("$fn")
    date_inputs+=("$dt")
    file_uids+=("$uid_col")
  done < "$file"

  if (( ${#filenames[@]} == 0 )); then err "no valid entries in $file"; return 1; fi
  log "read ${#filenames[@]} unique entries from $file"

  # --- Validate all dates up front.
  local -a norm_dates=() target_epochs=()
  local i nd te
  for (( i = 0; i < ${#filenames[@]}; i++ )); do
    nd=$(normalize_date "${date_inputs[$i]}") || { err "cannot parse date \"${date_inputs[$i]}\" for \"${filenames[$i]}\""; return 1; }
    te=$(to_epoch "$nd") || { err "cannot convert date \"$nd\""; return 1; }
    norm_dates+=("$nd")
    target_epochs+=("$te")
  done

  # --- Prefetch timeline ONCE; build compact uid index (single jq pass).
  # This makes precheck and per-photo lookups near-instant instead of one
  # full 162MB jq scan per entry (~2.9s each).
  local timeline_pre="$LOG_DIR/.timeline-pre-$$.json"
  if ! "$CLI" photo timeline -d --json > "$timeline_pre" 2>/dev/null; then
    err "timeline fetch failed (preflight)"; rm -f "$timeline_pre"; return 1
  fi
  local uid_index="$WORK_DIR/.uid-index.tsv"
  build_uid_index "$timeline_pre" "$uid_index"
  log "uid index built: $(wc -l < "$uid_index") entries from timeline"
  rm -f "$timeline_pre"

  # --- Precheck: uid-pinned entries via uid-set, name-based via name counts.
  local uid_set="$WORK_DIR/.uid-set.txt"
  cut -f1 "$uid_index" | sort -u > "$uid_set"
  local name_count_file="$WORK_DIR/.name-count.tsv"
  awk -F'\t' '{c[$2]++} END {for (n in c) print n"\t"c[n]}' "$uid_index" > "$name_count_file"

  declare -A skip_entry=()
  local precheck_bad=0 cnt
  for (( i = 0; i < ${#filenames[@]}; i++ )); do
    local fuid="${file_uids[$i]}"
    if [[ -n "$fuid" ]]; then
      if ! grep -F -x -q "$fuid" "$uid_set"; then
        err "precheck: nodeUid \"$fuid\" for \"${filenames[$i]}\" not found in timeline — skipping"
        skip_entry[$i]=1; precheck_bad=$((precheck_bad + 1))
      fi
    else
      cnt=$(awk -F'\t' -v n="${filenames[$i]}" '$1==n{print $2; exit}' "$name_count_file")
      cnt="${cnt:-0}"
      if (( cnt == 0 )); then
        err "precheck: \"${filenames[$i]}\" not found in timeline — skipping"
        skip_entry[$i]=1; precheck_bad=$((precheck_bad + 1))
      elif (( cnt > 1 )); then
        err "precheck: $cnt photos named \"${filenames[$i]}\" — ambiguous, aborting this entry (disambiguate manually)"
        skip_entry[$i]=1; precheck_bad=$((precheck_bad + 1))
      fi
    fi
  done
  if (( precheck_bad > 0 )); then
    log "precheck: $precheck_bad/${#filenames[@]} entries skipped (not found or ambiguous)"
  fi

  if (( DRY_RUN == 0 && YES == 0 )); then
    echo ""
    echo "This will fix photo(s) for each valid entry. Each photo will be:"
    if [[ -n "$LOCAL_SOURCE" ]]; then
      echo "  - Copied from local source ($LOCAL_SOURCE), not downloaded"
    else
      echo "  - Downloaded from Proton (kept in $WORK_DIR until fully fixed)"
    fi
    echo "  - Modified offline (mtime adjusted$([[ $EXIF_DATE == 1 ]] && echo " + EXIF dates rewritten"))"
    echo "  - Deleted from Proton (trash + permanent delete)"
    echo "  - Re-uploaded with the correct capture time (verified)"
    echo "  - Re-added to its original albums (verified)"
    echo ""
    local confirm=""
    read -r -p "Proceed? [y/N] " confirm || confirm=""
    [[ "$confirm" =~ ^[yY] ]] || { log "cancelled"; return 0; }
  fi

  # --- Build reverse album index from --album-cache (if provided).
  # Maps each filename to the list of album UIDs containing it.
  local name_albums_file="$WORK_DIR/.name-albums.tsv"
  declare -A name_albums=()
  if [[ -n "$ALBUM_CACHE" && -d "$ALBUM_CACHE" ]]; then
    log "building album index from $ALBUM_CACHE ..."
    local tmp_index="$WORK_DIR/.album-index-raw.json"
    : > "$tmp_index"
    find "$ALBUM_CACHE" -name '*.json' -exec sh -c '
      for f; do
        auid=$(basename "$f" .json)
        jq -c --arg a "$auid" ".[] | {name: .name.value, album: \$a}" "$f" 2>/dev/null
      done
    ' _ {} + >> "$tmp_index"
    # Group by filename into {name, albums: [uids...]}
    jq -r -s '
      group_by(.name) | map([.[0].name, ([.[].album] | join(","))]) | .[] | @tsv
    ' "$tmp_index" > "$name_albums_file"
    rm -f "$tmp_index"
    local n a
    while IFS=$'\t' read -r n a; do
      name_albums["$n"]="$a"
    done < "$name_albums_file"
    log "album index built: ${#name_albums[@]} filenames indexed"
  fi

  # --- Load local-source sha1 → path index (if provided).
  # Skip .supplemental-metadata.json and other .json sidecars when building.
  declare -A sha1_path=()
  if [[ -n "$LOCAL_SOURCE" ]]; then
    log "loading sha1 index from $INDEX_FILE ..."
    local s_idx s_p
    while read -r s_idx s_p; do
      [[ -z "$s_idx" || -z "$s_p" ]] && continue
      sha1_path["$s_idx"]="$s_p"
    done < "$INDEX_FILE"
    log "sha1 index loaded: ${#sha1_path[@]} files"
  fi

  # --- Load per-uid fields (uid, name, captureTime, sha1, albums) into
  # bash associative arrays so the per-photo loop never scans the timeline.
  declare -A uid_capture=() uid_sha1=() uid_albums=()
  local u n c s a
  while IFS=$'\t' read -r u n c s a; do
    uid_capture["$u"]="$c"
    uid_sha1["$u"]="$s"
    uid_albums["$u"]="$a"
  done < "$uid_index"

  local total=${#filenames[@]} fix_ok=0 fix_fail=0 fix_partial=0
  local pending_file="$WORK_DIR/.pending.tsv"
  : > "$pending_file"

  # ==========================================================================
  # PHASE B — fix every photo (download / verify / trash / delete / upload).
  # No timeline re-fetch here; new-uid location and album restore are batched
  # into a single final timeline fetch in PHASE C.
  # ==========================================================================
  for (( i = 0; i < total; i++ )); do
    if [[ -n "${skip_entry[$i]:-}" ]]; then continue; fi
    local fn="${filenames[$i]}" norm="${norm_dates[$i]}" target_epoch="${target_epochs[$i]}"
    local touch_fmt
    touch_fmt=$(to_touch_format "$norm") || { err "cannot build touch format for \"$norm\""; fix_fail=$((fix_fail+1)); continue; }
    log "[$((i+1))/$total] ==== $fn → $norm ===="

    # --- Lookup from prebuilt index (no timeline scans).
    local uid sha1_before albums_csv capture_before
    local fuid="${file_uids[$i]}"
    if [[ -n "$fuid" ]]; then
      uid="$fuid"
      if [[ -z "${uid_sha1[$fuid]:-}" ]]; then
        err "photo \"$fn\" (uid=$uid) not found in timeline"
        fix_fail=$((fix_fail+1)); continue
      fi
    else
      # name → uid fallback (rare, 2-col input): find first uid whose name matches
      uid=$(awk -F'\t' -v n="$fn" '$2==n{print $1; exit}' "$uid_index")
      if [[ -z "$uid" ]]; then
        err "photo \"$fn\" not found in timeline (was it removed since precheck?)"
        fix_fail=$((fix_fail+1)); continue
      fi
    fi
    sha1_before="${uid_sha1[$uid]:-}"
    capture_before="${uid_capture[$uid]:-}"
    albums_csv="${uid_albums[$uid]:-}"

    # Fallback: timeline often lacks photo.albums; use cache index if available
    if [[ -z "$albums_csv" && -n "${name_albums[$fn]:-}" ]]; then
      albums_csv="${name_albums[$fn]}"
      log "  album membership recovered from cache: $albums_csv"
    fi

    if [[ -z "$sha1_before" ]]; then
      err "photo \"$fn\": no claimed sha1 digest — refusing to proceed (cannot verify re-upload)"
      fix_fail=$((fix_fail+1)); continue
    fi
    log "  uid=$uid albums=${albums_csv:-none}"
    log "  current captureTime: $capture_before  sha1=$sha1_before"

    # --- Local source: resolve file path + real capture time override.
    local src_file="" real_ts=""
    if [[ -n "$LOCAL_SOURCE" ]]; then
      src_file="${sha1_path[$sha1_before]:-}"
      if [[ -z "$src_file" || ! -f "$src_file" ]]; then
        log "  WARN: sha1 not found in local source — falling back to download"
        src_file=""
      else
        log "  local source: $src_file"
        local sidecar="${src_file}.supplemental-metadata.json"
        if [[ -f "$sidecar" ]]; then
          real_ts=$(jq -r '.photoTakenTime.timestamp // empty' "$sidecar" 2>/dev/null)
          if [[ -n "$real_ts" && "$real_ts" =~ ^[0-9]+$ ]]; then
            local real_date real_epoch
            real_date=$(date -d "@$real_ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || real_date=""
            if [[ -n "$real_date" ]]; then
              real_epoch=$(to_epoch "$real_date" 2>/dev/null || echo "")
              if [[ -n "$real_epoch" && "$real_epoch" -ge 631152000 && "$real_epoch" -le $(date +%s) ]]; then
                log "  real capture time from Google metadata: $real_date (TSV target was $norm)"
                norm="$real_date"
                target_epoch="$real_epoch"
                norm_dates[$i]="$real_date"
                target_epochs[$i]="$real_epoch"
                touch_fmt=$(to_touch_format "$norm") || true
              else
                log "  WARN: sidecar photoTakenTime out of range ($real_date) — keeping TSV target $norm"
              fi
            fi
          fi
        fi
      fi
    fi

    # Idempotency: already at target (±120s)?
    local cur_epoch=""
    if [[ -n "$capture_before" ]]; then
      cur_epoch=$(to_epoch "$capture_before" 2>/dev/null || echo "")
    fi
    if [[ -n "$cur_epoch" ]]; then
      local delta=$(( cur_epoch > target_epoch ? cur_epoch - target_epoch : target_epoch - cur_epoch ))
      if (( delta <= 120 )); then
        log "  already at target date (±120s) — skipping"
        continue
      fi
      # Timezone mismatch? Check if the date part matches
      if [[ "${capture_before:0:10}" == "${norm:0:10}" ]]; then
        log "  already at target date (date matches, timezone offset ignored) — skipping"
        continue
      fi
    fi

    if (( DRY_RUN )); then
      local src_note="download"
      [[ -n "$src_file" && -f "$src_file" ]] && src_note="copy from local source"
      log "  DRY RUN: would $src_note, fix date to $norm, trash, delete, re-upload, re-add albums (${albums_csv:-none})"
      continue
    fi

    # --- Obtain the file bytes: copy from local source, else download from Proton.
    local dl="$WORK_DIR/dl-$i"
    rm -rf "$dl"; mkdir -p "$dl"
    if [[ -n "$src_file" && -f "$src_file" ]]; then
      log "  copying from local source ..."
      if ! cp "$src_file" "$dl/"; then
        err "copy from local source failed for $fn (kept work dir: $WORK_DIR)"; fix_fail=$((fix_fail+1)); continue
      fi
    else
      log "  downloading ..."
      if ! "$CLI" photo download "/photos/$uid" "$dl" > "$WORK_DIR/download-$i.out" 2>&1; then
        err "download failed for $fn (kept work dir: $WORK_DIR)"; fix_fail=$((fix_fail+1)); continue
      fi
    fi
    local -a candidates=()
    local cf
    while IFS= read -r -d '' cf; do candidates+=("$cf"); done < <(find "$dl" -type f -print0)
    if (( ${#candidates[@]} != 1 )); then
      err "expected exactly 1 file in $dl, found ${#candidates[@]} (kept: $dl)"
      fix_fail=$((fix_fail+1)); continue
    fi
    local local_path="${candidates[0]}"

    # --- Integrity: bytes must match the original sha1 (F14).
    local dl_sha1
    dl_sha1=$(sha1sum "$local_path" | awk '{print $1}')
    if [[ "$dl_sha1" != "$sha1_before" ]]; then
      err "sha1 mismatch for $fn ($dl_sha1 != $sha1_before) — refusing to destroy original (kept: $dl)"
      fix_fail=$((fix_fail+1)); continue
    fi

    # --- Rewrite EXIF date tags (optional, --exif-date).  This changes the
    # file content, so the sha1 recorded for the batch-verify lookup must be
    # recomputed afterwards (uploaded bytes differ from the original sha1).
    # Only image formats carry DateTimeOriginal/CreateDate/ModifyDate EXIF
    # tags; videos (mp4/mov) are handled via mtime instead.
    local sha1_uploaded="$sha1_before"
    if (( EXIF_DATE )); then
      local ext="${local_path##*.}"; ext="${ext,,}"
      case "$ext" in
        jpg|jpeg|heic|png|tif|tiff|nef|arw|dng|cr2)
          log "  rewriting EXIF dates to $norm ..."
          local exif_dt="${norm//-/:}"   # YYYY-MM-DD HH:MM:SS → YYYY:MM:DD HH:MM:SS
          if ! exiftool -overwrite_original \
                -DateTimeOriginal="$exif_dt" \
                -CreateDate="$exif_dt" \
                -ModifyDate="$exif_dt" \
                "$local_path" > "$WORK_DIR/exif-$i.out" 2>&1; then
            err "exiftool failed for $fn — see $WORK_DIR/exif-$i.out (kept: $dl)"
            fix_fail=$((fix_fail+1)); continue
          fi
          sha1_uploaded=$(sha1sum "$local_path" | awk '{print $1}')
          log "  sha1 after EXIF rewrite: $sha1_uploaded"
          ;;
      esac
    fi

    # --- Fix mtime (server TZ; override with TZ=... if needed).
    log "  setting mtime to $norm ($touch_fmt)"
    if ! touch -t "$touch_fmt" "$local_path"; then
      err "touch failed for $fn"; fix_fail=$((fix_fail+1)); continue
    fi

    # --- Persist state BEFORE any destructive step (F10).
    local state_file="$WORK_DIR/$fn.state"
    {
      printf 'uid=%s\n' "$uid"
      printf 'albums=%s\n' "$albums_csv"
      printf 'sha1=%s\n' "$sha1_before"
      printf 'sha1_uploaded=%s\n' "$sha1_uploaded"
      printf 'target=%s\n' "$norm"
      printf 'file=%s\n' "$local_path"
    } > "$state_file"

    # --- Trash old (failure here = original untouched, safe to retry later).
    log "  trashing old uid=$uid ..."
    local rc=0
    "$CLI" filesystem trash "/photos/$uid" > "$WORK_DIR/trash-$i.out" 2>&1 || rc=$?
    if (( rc != 0 )); then
      err "trash failed (rc=$rc) for $fn — original untouched (state: $state_file)"
      fix_fail=$((fix_fail+1)); continue
    fi

    # --- Permanently delete from trash (failure = recoverable in photos-trash).
    log "  permanently deleting ..."
    rc=0
    "$CLI" filesystem delete "/photos-trash/$fn" > "$WORK_DIR/delete-$i.out" 2>&1 || rc=$?
    if (( rc != 0 )); then
      err "delete from trash failed (rc=$rc) for $fn — photo is in photos-trash (uid=$uid); recover with: $CLI filesystem restore /photos-trash/$fn (state: $state_file)"
      fix_fail=$((fix_fail+1)); continue
    fi

    # --- Re-upload with retry (stale dedup cache after delete may skip once).
    local upload_ok=0 attempt=1 transferred=0 failures_json="[]"
    local upload_json="$WORK_DIR/upload-$i.json"
    while (( attempt <= 3 )); do
      log "  re-uploading (attempt $attempt/3, strategy: skip) ..."
      rc=0
      "$CLI" photo upload --json -c skip "$local_path" > "$upload_json" 2>"$WORK_DIR/upload-$i.err" || rc=$?
      transferred=$(jq -r '.transferredItems // 0' "$upload_json" 2>/dev/null || echo 0)
      failures_json=$(jq -c '.failures // []' "$upload_json" 2>/dev/null || echo "[]")
      log "  upload attempt $attempt: rc=$rc transferred=$transferred failures=$failures_json"
      if (( rc == 0 && transferred > 0 )); then upload_ok=1; break; fi
      if (( attempt < 3 )); then sleep $(( attempt * 10 )); fi
      attempt=$((attempt + 1))
    done
    if (( upload_ok == 0 )); then
      err "upload failed after 3 attempts for $fn — local copy preserved at $local_path (state: $state_file)"
      fix_fail=$((fix_fail+1)); continue
    fi

    # Upload succeeded: record for batch verification. Local bytes are now
    # safely re-uploaded to Proton, so free the disk copy right away (the
    # state file retains uid/sha1/albums for recovery). The sha1 recorded is
    # the sha1 of the UPLOADED bytes (== sha1_before unless --exif-date).
    printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$sha1_uploaded" "$uid" "${albums_csv:--}" "$norm" >> "$pending_file"
    rm -rf "$dl"
    log "  uploaded — deferred to batch verification"
  done

  # ==========================================================================
  # PHASE C — batch verification (single final timeline fetch).
  # Locate each uploaded photo's new uid by content sha1, verify the new
  # capture time, and restore album membership.
  # ==========================================================================
  if [[ -s "$pending_file" ]]; then
    local n_pending
    n_pending=$(wc -l < "$pending_file")
    log "batch verifying $n_pending uploaded photos ..."

    local final_timeline="$WORK_DIR/timeline-final.json"
    local final_index="$WORK_DIR/.uid-index-final.tsv"
    local sha1_uid_file="$WORK_DIR/.sha1-uid.tsv"
    local new_uid="" poll=0 found_all=0

    # Poll: fetch timeline, build sha1→newest-uid map; stop when all pending
    # sha1s are found (only re-fetches the timeline if something is missing).
    while (( poll < 6 )); do
      if "$CLI" photo timeline -d --json > "$final_timeline" 2>/dev/null; then
        build_uid_index "$final_timeline" "$final_index"
        # newest uid per sha1 (excludes nothing; old uid was deleted already)
        jq -r '
          group_by(.activeRevision.claimedDigests.sha1)
          | .[]
          | sort_by(.creationTime)
          | last
          | select((.activeRevision.claimedDigests.sha1 // "") != "")
          | [.activeRevision.claimedDigests.sha1, .uid] | @tsv
        ' "$final_timeline" 2>/dev/null > "$sha1_uid_file"
        declare -A sha1_uid=()
        local su s2
        while IFS=$'\t' read -r s2 su; do
          sha1_uid["$s2"]="$su"
        done < "$sha1_uid_file"
        # Are all pending sha1s present?
        found_all=1
        while IFS=$'\t' read -r _ s2 _ _ _; do
          if [[ -z "${sha1_uid[$s2]:-}" ]]; then found_all=0; break; fi
        done < "$pending_file"
        (( found_all == 1 )) && break
      fi
      poll=$((poll + 1))
      [[ $poll -lt 6 ]] && { log "  not all new uids visible yet (poll $poll/5), waiting ..."; sleep 10; }
    done

    if (( found_all == 0 )); then
      err "some new uids were not found after $poll timeline fetches — inspect $WORK_DIR/.pending.tsv and state files"
      fix_fail=$((fix_fail + n_pending))
    else
      # Preload capture times of the final index for verification.
      declare -A fin_uid_capture=()
      while IFS=$'\t' read -r u n c s a; do
        fin_uid_capture["$u"]="$c"
      done < "$final_index"

      local i2 sha1 albums_csv norm2 entry_partial new_capture new_capture_epoch cap_delta
      while IFS=$'\t' read -r i2 sha1 _old_uid albums_csv norm2; do
        [[ "$albums_csv" == "-" ]] && albums_csv=""
        fn="${filenames[$i2]}"
        target_epoch="${target_epochs[$i2]}"
        new_uid="${sha1_uid[$sha1]:-}"
        if [[ -z "$new_uid" ]]; then
          err "new uid not found for $fn (sha1=$sha1) — uploaded file needs manual inspection (state: $WORK_DIR/$fn.state)"
          fix_fail=$((fix_fail+1)); continue
        fi
        log "  [$fn] new uid=$new_uid"

        # --- Verify the new capture time actually matches the target (F13).
        entry_partial=0
        new_capture="${fin_uid_capture[$new_uid]:-}"
        new_capture_epoch=""
        if [[ -n "$new_capture" ]]; then
          new_capture_epoch=$(to_epoch "$new_capture" 2>/dev/null || echo "")
        fi
        if [[ -n "$new_capture_epoch" ]]; then
          cap_delta=$(( new_capture_epoch > target_epoch ? new_capture_epoch - target_epoch : target_epoch - new_capture_epoch ))
          if (( cap_delta > 120 )); then
            # Timezone offset? Check if the DATE part matches
            if [[ "${new_capture:0:10}" == "${norm2:0:10}" ]]; then
              log "  captureTime verified: $new_capture (date matches, timezone offset ignored)"
            else
              err "captureTime mismatch for $fn: got $new_capture, target $norm2 (delta ${cap_delta}s) — photo re-uploaded but date NOT fixed"
              entry_partial=1
            fi
          else
            log "  captureTime verified: $new_capture"
          fi
        else
          log "  WARN: could not read new captureTime for verification (new uid=$new_uid)"
        fi

        # --- Restore album membership, checking per-photo ok (F11).
        if [[ -n "$albums_csv" ]]; then
          local -a album_uids=()
          IFS=',' read -ra album_uids <<< "$albums_csv"
          local auid add_rc=0 add_ok="" add_out="$WORK_DIR/album-add-$i2.json"
          for auid in "${album_uids[@]}"; do
            [[ -z "$auid" ]] && continue
            log "  adding to album $auid ..."
            add_rc=0
            "$CLI" album add-photo --json "/albums/$auid" "/photos/$new_uid" > "$add_out" 2>"$WORK_DIR/album-add-$i2.err" || add_rc=$?
            add_ok=$(jq -r 'first(.[]?) // empty | (.ok // false)' "$add_out" 2>/dev/null || echo "false")
            if (( add_rc != 0 )) || [[ "$add_ok" != "true" ]]; then
              err "album add-photo failed for $auid (photo $new_uid, rc=$add_rc ok=$add_ok)"
              entry_partial=1
            else
              log "    done"
            fi
          done
        fi

        if (( entry_partial == 0 )); then
          rm -f "$WORK_DIR/$fn.state" "$WORK_DIR/download-$i2.out" "$WORK_DIR/trash-$i2.out" "$WORK_DIR/delete-$i2.out" "$WORK_DIR/upload-$i2.json" "$WORK_DIR/upload-$i2.err" "$WORK_DIR/album-add-$i2.json" "$WORK_DIR/album-add-$i2.err" "$WORK_DIR/timeline-now-$i2.json"
          fix_ok=$((fix_ok + 1))
          log "  OK"
        else
          fix_partial=$((fix_partial + 1))
          log "  PARTIAL (kept state file for $fn)"
        fi
      done < "$pending_file"
    fi
  fi

  log "==== done: $fix_ok fixed, $fix_partial partial, $fix_fail failed ===="

  if (( fix_fail > 0 )); then
    err "$fix_fail photo(s) failed — preserved work dir: $WORK_DIR (log: $RUN_LOG)"
    return 1
  fi
  if (( fix_partial > 0 )); then
    log "WARN: $fix_partial photo(s) partially fixed — review $WORK_DIR (log: $RUN_LOG)"
    return 0
  fi
  rm -rf "$WORK_DIR"
  return 0
}

main "$@"
