#!/usr/bin/env bash
#
# gphoto2proton-import.sh
#
# Import Google Photos Takeout archives (.tgz) into Proton Photos using the
# official `proton-drive` CLI (ProtonDriveApps/sdk). Archives are processed one
# at a time: extract -> manifest -> upload -> verify -> recreate albums ->
# validate -> cleanup. The original .tgz archives are always kept.
#
# Authentication: the CLI reads its session from the `pass` secret store, so
# this script exports PROTON_DRIVE_CREDENTIALS_STORE=pass by default (override
# with the environment). If the session is lost, run `proton-drive auth login`.
#
# EXIF: nothing to do — the CLI reads the capture time directly from each
# file's EXIF on upload (verified against iPhone HEIC files).
#
# NOTE: this script targets Linux (GNU stat/tar/flock). It runs on the server
# where the `proton-drive` CLI is installed.
#
# Usage:
#   gphoto2proton-import.sh [--check] [--force] [--keep-work] [--resume]
#                           [--albums-only] [--convert-raw]
#                           [--reprocess-recovery] [--archive NAME]
#
# Env vars (defaults shown):
#   CLI                            proton-drive
#   TAKEOUT_DIR                    $HOME/gphoto2proton/takeout
#   WORK_DIR                       $HOME/gphoto2proton/work
#   LOG_DIR                        $HOME/gphoto2proton/logs
#   STATE_DIR                      $HOME/gphoto2proton/state
#   PROTON_DRIVE_CREDENTIALS_STORE pass
#   CHUNK_SIZE                     200
#
set -euo pipefail

CLI="${CLI:-proton-drive}"
TAKEOUT_DIR="${TAKEOUT_DIR:-$HOME/gphoto2proton/takeout}"
WORK_DIR="${WORK_DIR:-$HOME/gphoto2proton/work}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
STATE_DIR="${STATE_DIR:-$HOME/gphoto2proton/state}"
CHUNK_SIZE="${CHUNK_SIZE:-200}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

RUN_TS=""
RUN_LOG=""
DONE_FILE="$STATE_DIR/done"
RECOVERY_FILE="$STATE_DIR/recovery.tsv"
RAW_CONVERSIONS_FILE="$STATE_DIR/raw-conversions.tsv"
KEEP_WORK=0
RESUME=0
ALBUMS_ONLY=0
CONVERT_RAW=0
REPROCESS_RECOVERY=0
RECOVERY_FILTER=""
RAW_CONVERTER=""

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG" >&2; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" | tee -a "$RUN_LOG" >&2; }

usage() {
  cat <<'EOF'
Import Google Photos Takeout archives into Proton Photos.

Usage:
  gphoto2proton-import.sh [options]

Options:
  --check          Read-only: verify auth, list pending/done archives, exit.
  --force          Reprocess archives already marked as done.
  --keep-work      Keep extracted files after a successful import.
  --resume         Skip upload/verify if artifacts from a previous run exist.
  --albums-only    Only recreate albums from already-uploaded photos
                   (also reprocesses archives already marked as done).
  --convert-raw    Convert unsupported RAW formats (NEF/CR2/ARW) to JPEG
                   before upload, so they can be ingested by Proton Photos.
                   Uses darktable-cli, or dcraw + ImageMagick convert.
  --reprocess-recovery
                   Re-process the files recorded in recovery.tsv: re-extract
                   the archive, convert RAW -> JPEG, upload, add them to
                   albums and clear the resolved entries. Implies --convert-raw.
  --archive NAME   Process only the given archive (basename or path).
  -h, --help       Show this help.
EOF
}

is_media() {
  case "${1##*.}" in
    jpg|jpeg|png|gif|heic|mov|mp4|cr2|nef|arw|JPG|JPEG|PNG|GIF|HEIC|MOV|MP4|CR2|NEF|ARW) return 0 ;;
    *) return 1 ;;
  esac
}

# RAW camera formats that the proton-drive CLI cannot ingest into Photos.
is_raw() {
  case "${1##*.}" in
    nef|cr2|arw|NEF|CR2|ARW) return 0 ;;
    *) return 1 ;;
  esac
}

# Detect the best available RAW -> JPEG converter.
# Priority: darktable-cli (direct JPEG, preserves EXIF) > dcraw+convert.
detect_raw_converter() {
  if command -v darktable-cli >/dev/null 2>&1; then
    echo "darktable-cli"
  elif command -v dcraw >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
    echo "dcraw+convert"
  fi
}

# Convert a single RAW file to JPEG using the detected converter.
convert_one_raw() {
  local src="$1" dst="$2" converter="$3" artifacts="$4"
  case "$converter" in
    darktable-cli)
      darktable-cli "$src" "$dst" >/dev/null 2>"$artifacts/raw-convert.err"
      ;;
    dcraw+convert)
      dcraw -c "$src" 2>"$artifacts/raw-convert.err" | convert - "$dst"
      ;;
    *) return 1 ;;
  esac
}

# Convert RAW files (NEF/CR2/ARW) to JPEG in place, so the rest of the pipeline
# (manifest, upload, albums) only ever sees supported media. When RECOVERY_FILTER
# is set, only the RAW files listed there (a recovery.tsv relpath per line) are
# converted. Every conversion is logged to the global raw-conversions.tsv and to
# the per-archive artifact log.
convert_raw_files() {
  local gp_dir="$1" artifacts="$2" archive_name="$3"
  local converter="$RAW_CONVERTER"
  if [[ -z "$converter" ]]; then
    log "  no RAW converter available — skipping RAW conversion (files will land in recovery.tsv)"
    return 0
  fi
  local conv_log="$artifacts/raw-conversions.tsv"
  : > "$conv_log"
  : > "$artifacts/raw-conversion-failed.tsv"
  local count=0 fail=0 f rel base dir out new_rel n=0
  local orig_sha orig_size new_sha new_size
  while IFS= read -r -d '' f; do
    is_raw "$f" || continue
    is_junk "$f" && continue
    rel="${f#"$gp_dir"/}"
    if [[ -n "$RECOVERY_FILTER" ]] && ! grep -qxF "$rel" "$RECOVERY_FILTER"; then
      continue
    fi
    dir=$(dirname "$f")
    base=$(basename "$f")
    out="$dir/${base%.*}.jpg"
    n=0
    while [[ -e "$out" ]]; do
      n=$((n + 1))
      out="$dir/${base%.*}-converted-$n.jpg"
    done
    new_rel="${out#"$gp_dir"/}"
    orig_sha=$(sha1sum "$f" | awk '{print $1}')
    orig_size=$(stat -c%s "$f")
    if ! convert_one_raw "$f" "$out" "$converter" "$artifacts" || [[ ! -s "$out" ]]; then
      err "  RAW conversion FAILED: $rel (see $artifacts/raw-convert.err) — left as-is"
      printf '%s\t%s\t%s\t%s\tmissing_from_timeline\n' "$orig_sha" "$orig_size" "$archive_name" "$rel" >> "$artifacts/raw-conversion-failed.tsv"
      fail=$((fail + 1))
      continue
    fi
    # dcraw outputs PPM with no EXIF; copy metadata from the RAW if exiftool exists
    # (darktable-cli already embeds EXIF).
    if [[ "$converter" == "dcraw+convert" ]] && command -v exiftool >/dev/null 2>&1; then
      exiftool -q -overwrite_original "-TagsFromFile" "$f" "$out" >/dev/null 2>"$artifacts/raw-exif.err" || true
    fi
    rm -f "$f"
    new_sha=$(sha1sum "$out" | awk '{print $1}')
    new_size=$(stat -c%s "$out")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$archive_name" "$converter" "$rel" "$new_rel" "$orig_size" "$new_size" "$orig_sha" "$new_sha" >> "$RAW_CONVERSIONS_FILE"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$converter" "$rel" "$new_rel" "$orig_size" "$new_size" "$orig_sha" "$new_sha" >> "$conv_log"
    count=$((count + 1))
  done < <(find "$gp_dir" -type f -print0)
  if (( fail > 0 )); then
    log "  RAW conversion: $count converted, $fail failed — failed files remain in recovery.tsv"
  else
    log "  RAW conversion: $count files converted to JPEG ($converter)"
  fi
  return 0
}

# Skip macOS metadata junk (AppleDouble resource forks, .DS_Store) that a
# macOS-created tar may embed; the CLI would otherwise treat them as media.
is_junk() {
  local base
  base=$(basename "$1")
  [[ "$base" == ._* ]] || [[ "$base" == ".DS_Store" ]]
}

# Remove junk files from an extracted tree (runs once right after extraction).
strip_junk() {
  find "$1" \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
}

is_done() { grep -qxF "$1" "$DONE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" || echo "$1" >> "$DONE_FILE"; }

# Apply capture dates from Google Photos sidecar JSON (<file>.<ext>.json).
# Images: CLI reads EXIF natively (correct by default).
# Videos: CLI falls back to filesystem mtime (which is the archive creation time).
# We read the original photoTakenTime.timestamp from the sidecar and set mtime
# via touch -t, so the CLI picks up the correct capture date for videos too.
apply_sidecar_dates() {
  local gp_dir="$1"
  local f sidecar epoch formatted count=0
  while IFS= read -r -d '' f; do
    is_media "$f" || continue
    sidecar="${f}.supplemental-metadata.json"
    [[ -f "$sidecar" ]] || continue
    epoch=$(jq -r '.photoTakenTime.timestamp // empty' "$sidecar" 2>/dev/null || true)
    [[ -n "$epoch" ]] || continue
    if formatted=$(date -d "@$epoch" '+%Y%m%d%H%M.%S' 2>/dev/null); then
      if touch -t "$formatted" "$f" 2>/dev/null; then
        count=$((count + 1))
      fi
    fi
  done < <(find "$gp_dir" -type f -print0)
  log "applied capture dates from sidecar JSON to $count files"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  local -a missing=()
  local b
  for b in "$CLI" tar jq sha1sum flock df stat; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "missing required binaries: ${missing[*]}"
    return 1
  fi

  local d
  for d in "$TAKEOUT_DIR" "$WORK_DIR" "$LOG_DIR" "$STATE_DIR"; do
    mkdir -p "$d" || { err "cannot create $d"; return 1; }
  done

  if ! "$CLI" album list --json >/dev/null 2>"$LOG_DIR/auth-probe.err"; then
    err "proton-drive is not authenticated. Run: $CLI auth login  (store: $PROTON_DRIVE_CREDENTIALS_STORE)"
    return 1
  fi
  log "authentication OK (store: $PROTON_DRIVE_CREDENTIALS_STORE)"

  local avail_mb need_mb largest_bytes=0 f size_bytes
  avail_mb=$(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}')
  avail_mb=$((avail_mb / 1024))
  for f in "$TAKEOUT_DIR"/*.tgz; do
    [[ -f "$f" ]] || continue
    size_bytes=$(stat -c%s "$f")
    (( size_bytes > largest_bytes )) && largest_bytes=$size_bytes
  done
  # Peak usage ~ archive + its extraction (~ same size) + buffer.
  need_mb=$(( (largest_bytes / 1024 / 1024) * 2 + 2048 ))
  if (( avail_mb < need_mb )); then
    err "not enough free disk space: avail=${avail_mb}MB, need~=${need_mb}MB (largest archive x2 + 2GB buffer)"
    return 1
  fi
  log "disk space OK: avail=${avail_mb}MB, need~=${need_mb}MB"
  return 0
}

# ---------------------------------------------------------------------------
# Check mode (read-only)
# ---------------------------------------------------------------------------
check_mode() {
  log "== Authentication =="
  if "$CLI" album list --json >/dev/null 2>&1; then
    log "  authenticated (PROTON_DRIVE_CREDENTIALS_STORE=$PROTON_DRIVE_CREDENTIALS_STORE)"
  else
    err "  not authenticated — run: $CLI auth login"
    return 1
  fi
  log "== Archives in $TAKEOUT_DIR =="
  local found=0 f base
  for f in "$TAKEOUT_DIR"/*.tgz; do
    [[ -f "$f" ]] || continue
    found=1
    base=$(basename "$f")
    if is_done "$base"; then
      log "  [done]    $base"
    else
      log "  [pending] $base"
    fi
  done
  if (( found == 0 )); then
    log "  (none found — expected takeout-001.tgz ... takeout-008.tgz)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Manifest: index media files (sha1/size/relpath) under the given dirs
# ---------------------------------------------------------------------------
build_manifest() {
  local gp_dir="$1" tsv="$2" json="$3"
  shift 3
  local -a dirs=("$@")
  : > "$tsv"
  local d f rel sha size count=0 throttle=0
  for d in "${dirs[@]}"; do
    while IFS= read -r -d '' f; do
      is_media "$f" || continue
      is_junk "$f" && continue
      rel="${f#"$gp_dir"/}"
      sha=$(sha1sum "$f" | awk '{print $1}')
      size=$(stat -c%s "$f")
      printf '%s\t%s\t%s\n' "$sha" "$size" "$rel" >> "$tsv"
      count=$((count + 1))
      throttle=$((throttle + 1))
      if (( throttle >= 500 )); then
        log "  sha1sum progress: $count files hashed"
        throttle=0
      fi
    done < <(find "$d" -type f -print0)
  done
  log "  sha1sum complete: $count files"
  jq -Rsr --argjson count "$count" '
    split("\n") | map(select(length > 0)) | map(split("\t")) |
    { media_count: $count,
      media: map({ sha1: .[0], size: (.[1] | tonumber), relpath: .[2] }) }
  ' "$tsv" > "$json"
}

# ---------------------------------------------------------------------------
# Recovery manifest: index only the files listed in a recovery filter
# (one relpath per line). RAW entries are resolved to their converted .jpg
# counterpart when present.
# ---------------------------------------------------------------------------
build_recovery_manifest() {
  local gp_dir="$1" filter_file="$2" tsv="$3" json="$4"
  : > "$tsv"
  local rel out sha size count=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    out="$gp_dir/$rel"
    if is_raw "$rel" && [[ -f "$gp_dir/${rel%.*}.jpg" ]]; then
      out="$gp_dir/${rel%.*}.jpg"
    fi
    if [[ ! -f "$out" ]]; then
      log "  WARN: recovery file not found in extraction: $rel"
      continue
    fi
    sha=$(sha1sum "$out" | awk '{print $1}')
    size=$(stat -c%s "$out")
    printf '%s\t%s\t%s\n' "$sha" "$size" "${out#"$gp_dir"/}" >> "$tsv"
    count=$((count + 1))
  done < "$filter_file"
  log "  recovery manifest: $count files"
  jq -Rsr --argjson count "$count" '
    split("\n") | map(select(length > 0)) | map(split("\t")) |
    { media_count: $count,
      media: map({ sha1: .[0], size: (.[1] | tonumber), relpath: .[2] }) }
  ' "$tsv" > "$json"
}

# ---------------------------------------------------------------------------
# Albums: JSON array of {name, members:[{filename,size,sha1}]}
# Primary source: physical files in Albums/<name>/. Fallback: album.json.
# ---------------------------------------------------------------------------
discover_albums() {
  local gp_dir="$1" out="$2"
  local albums_root="$gp_dir/Albums"
  echo '[]' > "$out"
  [[ -d "$albums_root" ]] || return 0

  local tmp="$WORK_DIR/.album_tsv.$$"
  local first=1 album_dir name tsv f sha size members_json aj
  {
    echo '['
    for album_dir in "$albums_root"/*/; do
      [[ -d "$album_dir" ]] || continue
      name=$(basename "$album_dir")
      tsv="$tmp"
      : > "$tsv"
      while IFS= read -r -d '' f; do
        is_media "$f" || continue
        is_junk "$f" && continue
        sha=$(sha1sum "$f" | awk '{print $1}')
        size=$(stat -c%s "$f")
        printf '%s\t%s\t%s\n' "$sha" "$size" "$(basename "$f")" >> "$tsv"
      done < <(find "$album_dir" -type f -print0)

      if [[ -s "$tsv" ]]; then
        members_json=$(jq -Rsr '
          split("\n") | map(select(length > 0)) | map(split("\t")) |
          map({ filename: .[2], size: (.[1] | tonumber), sha1: .[0] })
        ' "$tsv")
      else
        aj="$album_dir/album.json"
        if [[ -f "$aj" ]]; then
          members_json=$(jq -c '[.MediaItems[]? | select(.title != null) | { filename: .title, size: 0, sha1: "" }]' "$aj" 2>/dev/null || echo '[]')
        else
          members_json='[]'
        fi
      fi

      if (( first == 0 )); then echo ','; fi
      jq -n --arg name "$name" --argjson members "$members_json" '{ name: $name, members: $members }'
      first=0
    done
    echo ']'
  } > "$out"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Timeline index: sha1 -> uid, name -> uid
# ---------------------------------------------------------------------------
build_timeline_index() {
  local json="$1" base="$2"
  jq -r '.[] | select(.activeRevision.claimedDigests.sha1 != null) | [.activeRevision.claimedDigests.sha1, .uid] | @tsv' "$json" | sort -u > "$base.sha1"
  jq -r '.[] | select(.name.ok == true) | [.name.value, .uid] | @tsv' "$json" | sort -u > "$base.name"
}

sha1_to_uid() {
  local sha="$1" index="$2" uid
  uid=$(awk -F '\t' -v s="$sha" '$1 == s { print $2; exit }' "$index")
  printf '%s' "$uid"
}

name_to_uid() {
  local name="$1" index="$2" uid
  uid=$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$index")
  printf '%s' "$uid"
}

# ---------------------------------------------------------------------------
# Albums: create missing, add photos (chunked), validate membership
# ---------------------------------------------------------------------------
process_albums() {
  local albums_json="$1" timeline_base="$2" artifacts="$3"
  local album_count
  album_count=$(jq 'length' "$albums_json")
  log "  albums: $album_count found in takeout"
  if (( album_count == 0 )); then
    echo '[]' > "$artifacts/albums.json"
    return 0
  fi

  local existing_json="$artifacts/albums-existing.json"
  "$CLI" album list --json > "$existing_json" 2>"$artifacts/albums-list.err"; rc=$?
  if (( rc != 0 )); then
    err "album list failed"; return 1
  fi

  local first=1 idx rc
  {
    echo '['
    for (( idx = 0; idx < album_count; idx++ )); do
      local name nmembers
      name=$(jq -r --argjson i "$idx" '.[$i].name' "$albums_json")
      nmembers=$(jq -r --argjson i "$idx" '.[$i].members | length' "$albums_json")
      log "  album: \"$name\" ($nmembers members)"

      if (( nmembers == 0 )); then
        log "    WARN: empty album, skipping"
        continue
      fi
      if (( nmembers > 10000 )); then
        err "album \"$name\" has $nmembers members (Proton limit is 10000). Split it in Google Photos first."
        return 1
      fi

      local album_uid=""
      album_uid=$(jq -r --arg n "$name" '.[] | select(.name.value == $n) | .uid' "$existing_json" | head -1)
      if [[ -n "$album_uid" ]]; then
        log "    exists, reusing uid $album_uid"
      else
        local create_json="$artifacts/album-create-$name.json"
        "$CLI" album create --json "$name" > "$create_json" 2>"$artifacts/album-create-$name.err"; rc=$?
        if (( rc != 0 )); then
          err "album create failed for \"$name\""; return 1
        fi
        album_uid=$(jq -r '.uid' "$create_json")
        log "    created uid $album_uid"
      fi

      # Resolve member uids (sha1 -> uid, fallback name -> uid), dedupe.
      local -a uid_list=() seen=()
      local j n m_sha1 m_name m_uid dup
      for (( j = 0; j < nmembers; j++ )); do
        m_sha1=$(jq -r --argjson i "$idx" --argjson j "$j" '.[$i].members[$j].sha1' "$albums_json")
        m_name=$(jq -r --argjson i "$idx" --argjson j "$j" '.[$i].members[$j].filename' "$albums_json")
        m_uid=""
        if [[ -n "$m_sha1" ]]; then
          m_uid=$(sha1_to_uid "$m_sha1" "$timeline_base.sha1")
        fi
        if [[ -z "$m_uid" ]]; then
          m_uid=$(name_to_uid "$m_name" "$timeline_base.name")
        fi
        if [[ -z "$m_uid" ]]; then
          log "    WARN: no timeline match for \"$m_name\" (sha1 ${m_sha1:-none})"
          continue
        fi
        dup=0
        for n in "${seen[@]}"; do [[ "$n" == "$m_uid" ]] && dup=1 && break; done
        if (( dup == 0 )); then
          seen+=("$m_uid")
          uid_list+=("$m_uid")
        fi
      done

      if (( ${#uid_list[@]} == 0 )); then
        err "album \"$name\": no members could be matched to the timeline"; return 1
      fi

      local -a photo_paths=()
      for n in "${uid_list[@]}"; do photo_paths+=("/photos/$n"); done
      local total=${#photo_paths[@]} start=0 end=0 ok_total=0 fail_total=0
      local album_path="/albums/$album_uid"
      while (( start < total )); do
        end=$((start + CHUNK_SIZE)); (( end > total )) && end=$total
        local batch=("${photo_paths[@]:start:CHUNK_SIZE}") add_out okc failc
        add_out=$("$CLI" album add-photo --json "$album_path" "${batch[@]}" 2>"$artifacts/album-add-$name.err"); rc=$?
        if (( rc != 0 )); then
          err "album add-photo batch failed (rc=$rc) for \"$name\""; return 1
        fi
        okc=$(jq '[.[] | select(.ok == true)] | length' <<<"$add_out")
        failc=$(jq '[.[] | select(.ok != true)] | length' <<<"$add_out")
        ok_total=$((ok_total + okc)); fail_total=$((fail_total + failc))
        log "    added $okc/$((end - start)) photos to \"$name\" ($fail_total failures so far)"
        start=$end
      done
      (( fail_total > 0 )) && { err "album \"$name\": $fail_total member adds failed"; return 1; }

      local album_artifacts="$artifacts/album-$name.json"
      jq -n --arg name "$name" --arg uid "$album_uid" --argjson expected "$nmembers" --argjson added "${#uid_list[@]}" --argjson ok "$ok_total" \
        '{ name: $name, uid: $uid, expected_members: $expected, matched_members: $added, added_ok: $ok }' > "$album_artifacts"

      if (( first == 0 )); then echo ','; fi
      cat "$album_artifacts"
      first=0
    done
    echo ']'
  } > "$artifacts/albums.json"
  return 0
}

# ---------------------------------------------------------------------------
# Validation: check all media present in the timeline. Missing files are logged
# to a recovery file for later reprocessing — NOT fatal.
# ---------------------------------------------------------------------------
validate_media() {
  local manifest="$1" timeline_base="$2" artifacts="$3" recovery_file="$4" archive_name="$5"
  local total missing_count=0 i sha uid relpath size
  total=$(jq '.media_count' "$manifest")
  if (( total == 0 )); then
    log "  validation: no media files found in timeline folders"
    return 0
  fi
  local report="$artifacts/validation-missing.tsv"
  : > "$report"
  for (( i = 0; i < total; i++ )); do
    sha=$(jq -r --argjson i "$i" '.media[$i].sha1' "$manifest")
    uid=$(sha1_to_uid "$sha" "$timeline_base.sha1")
    if [[ -z "$uid" ]]; then
      missing_count=$((missing_count + 1))
      relpath=$(jq -r --argjson i "$i" '.media[$i].relpath' "$manifest")
      size=$(jq -r --argjson i "$i" '.media[$i].size' "$manifest")
      printf '%s\n' "$relpath" >> "$report"
      printf '%s\t%s\t%s\t%s\tmissing_from_timeline\n' "$sha" "$size" "$archive_name" "$relpath" >> "$recovery_file"
    fi
  done
  log "  validation: $((total - missing_count))/$total media sha1s found in timeline"
  if (( missing_count > 0 )); then
    log "  WARN: $missing_count media files missing from timeline (see $report)"
    # Dedupe: reruns (--force/--resume/--albums-only) re-append the same rows.
    local rtmp
    rtmp=$(mktemp)
    sort -u "$recovery_file" > "$rtmp" && mv "$rtmp" "$recovery_file"
    log "  entries recorded in recovery file: $recovery_file"
  fi
  return 0
}

validate_albums() {
  local result_json="$1" takeout_json="$2" timeline_base="$3" artifacts="$4"
  jq empty "$result_json" 2>/dev/null || { err "albums.json is invalid — album processing may have failed"; return 1; }
  jq empty "$takeout_json" 2>/dev/null || { err "albums-takeout.json is invalid"; return 1; }
  local n a_fail=0
  n=$(jq 'length' "$result_json")
  if (( n == 0 )); then log "  validation: no albums to validate"; return 0; fi
  local idx uid takeout_name expected_shas actual_shas rc
  for (( idx = 0; idx < n; idx++ )); do
    uid=$(jq -r --argjson i "$idx" '.[$i].uid' "$result_json")
    takeout_name=$(jq -r --argjson i "$idx" '.[$i].name' "$takeout_json")
    local actual_json="$artifacts/album-photos-$uid.json"
    "$CLI" album photos -d --json "/albums/$uid" > "$actual_json" 2>"$artifacts/album-photos-$uid.err"; rc=$?
    if (( rc != 0 )); then
      err "album photos failed for $uid"; a_fail=$((a_fail + 1)); continue
    fi
    expected_shas=$(jq -c --argjson i "$idx" '
      .[$i].members | map(select(.sha1 != "" and .sha1 != "0")) | map(.sha1) | unique
    ' "$takeout_json")
    actual_shas=$(jq -c '[.[] | select(.activeRevision.claimedDigests.sha1 != null) | .activeRevision.claimedDigests.sha1] | unique' "$actual_json")
    local e a
    e=$(jq 'length' <<<"$expected_shas")
    a=$(jq 'length' <<<"$actual_shas")
    local missing_elem
    missing_elem=$(jq -n --argjson exp "$expected_shas" --argjson act "$actual_shas" \
      '[ $exp[] | select(. as $x | $act | index($x) | not) ] | length')
    if (( missing_elem > 0 )); then
      err "album \"$takeout_name\": $missing_elem/$e expected members not in album"
      a_fail=$((a_fail + 1))
    else
      log "  validation: album \"$takeout_name\" verified ($e/$e)"
    fi
  done
  (( a_fail > 0 )) && log "  WARN: $a_fail album(s) had membership issues (see above)"
  echo "$a_fail"
  return 0
}

# ---------------------------------------------------------------------------
# One archive
# ---------------------------------------------------------------------------
run_archive() {
  local archive="$1" index="$2" total="$3"
  local base artifacts extract_dir gp_dir
  base=$(basename "$archive")
  artifacts="$LOG_DIR/run-$RUN_TS/$base"
  mkdir -p "$artifacts"

  log ""
  log "==== $base ($index/$total) ===="

  extract_dir="$WORK_DIR/$base"
  gp_dir=$(find "$extract_dir" -type d -name "Google Photos" 2>/dev/null | head -1)
  if [[ -d "$extract_dir" ]] && [[ -n "$gp_dir" ]]; then
    log "extraction exists, resuming ..."
  else
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    log "extracting $archive ..."
    if ! tar xzf "$archive" -C "$extract_dir" > "$artifacts/tar.out" 2>&1; then
      err "tar extraction failed (see $artifacts/tar.out)"; rm -rf "$extract_dir"; return 1
    fi

    gp_dir=$(find "$extract_dir" -type d -name "Google Photos" | head -1)
    if [[ -z "$gp_dir" ]]; then
      local any_media
      any_media=$(find "$extract_dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.heic' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.cr2' -o -iname '*.nef' -o -iname '*.arw' \) -print0 2>/dev/null | xargs -0 -I {} echo 1 | head -c 1)
      if [[ -z "$any_media" ]]; then
        log "no 'Google Photos' directory and no media files — treating as empty archive"
        jq -n --arg archive "$base" '{ archive: $archive, status: "EMPTY", expected_media: 0, media_missing: 0, album_failures: 0, albums_processed: 0 }' > "$artifacts/summary.json"
        rm -rf "$extract_dir"
        mark_done "$base"
        return 0
      else
        err "no 'Google Photos' directory found in $base (but other files exist — unexpected structure)"
        rm -rf "$extract_dir"
        return 1
      fi
    fi
  fi

  log "stripping macOS metadata junk (._*, .DS_Store) ..."
  strip_junk "$extract_dir"

  # Sidecar dates only matter for upload (CLI reads mtime); skip in albums-only
  # and recovery modes (recovery re-processes already-dated files).
  if (( ALBUMS_ONLY == 0 )) && (( REPROCESS_RECOVERY == 0 )); then
    log "applying original capture dates from sidecar JSON ..."
    apply_sidecar_dates "$gp_dir"
  fi

  # RAW conversion: turn unsupported NEF/CR2/ARW into JPEG before the manifest
  # is built, so they flow through upload/albums like any other photo.
  if (( CONVERT_RAW )) && [[ -n "$RAW_CONVERTER" ]]; then
    convert_raw_files "$gp_dir" "$artifacts" "$base"
  fi

  # Empty-archive check: bail early if no media files anywhere.
  local any_media
  any_media=$(find "$gp_dir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.heic' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.cr2' -o -iname '*.nef' -o -iname '*.arw' \) -print0 2>/dev/null | xargs -0 -I {} echo 1 2>/dev/null | head -c 1)
  if [[ -z "$any_media" ]]; then
    log "no media files found — treating as empty archive"
    jq -n --arg archive "$base" '{ archive: $archive, status: "EMPTY", expected_media: 0, media_missing: 0, album_failures: 0, albums_processed: 0 }' > "$artifacts/summary.json"
    rm -rf "$extract_dir"
    mark_done "$base"
    return 0
  fi

  # Manifest: sha1sum of every media file in the whole Google Photos tree, or
  # (recovery mode) only of the files listed in the recovery filter.
  local manifest_tsv="$artifacts/manifest.tsv" manifest_json="$artifacts/manifest.json"
  if (( REPROCESS_RECOVERY )); then
    build_recovery_manifest "$gp_dir" "$RECOVERY_FILTER" "$manifest_tsv" "$manifest_json"
  elif [[ -f "$manifest_json" ]]; then
    log "reusing cached manifest ($(jq '.media_count' "$manifest_json") files)"
  else
    log "building manifest (sha1sum of all media files) ..."
    build_manifest "$gp_dir" "$manifest_tsv" "$manifest_json" "$gp_dir"
  fi
  local expected_media expected_unique
  expected_media=$(jq '.media_count' "$manifest_json")
  expected_unique=$(jq '[.media[] | .sha1] | unique | length' "$manifest_json")
  log "expected media: $expected_media files ($expected_unique unique)"

  # Upload: whole tree.  The proton-drive CLI flattens folders, dedups by
  # name+sha1, and only processes image/* and video/* (sidecar .json etc. are
  # silently ignored).  Album-folder copies of the same photo are skipped.
  local upload_json="$artifacts/upload.json" rc
  local verify_json="$artifacts/upload-verify.json"
  local timeline_json="$artifacts/timeline.json" timeline_base="$artifacts/timeline-index"
  local transferred=0 skipped=0 failed=0
  local run_mode="import"

  # --resume: locate the most recent PREVIOUS run's artifacts for this archive.
  # (This run's artifact dir run-$RUN_TS/$base was just created empty above, so
  # previous runs must be found under their own run-<ts> directories.)
  local prev_artifacts=""
  if (( RESUME )) && (( ALBUMS_ONLY == 0 )); then
    local d
    for d in "$LOG_DIR"/run-*/"$base"; do
      [[ -d "$d" ]] || continue
      [[ "$d" == "$LOG_DIR/run-$RUN_TS/$base" ]] && continue
      # only complete artifact dirs qualify (albums-only runs have no upload.json)
      [[ -s "$d/timeline-index.sha1" ]] || continue
      [[ -s "$d/timeline-index.name" ]] || continue
      jq -e '.transferredItems and .skippedItems and .failedItems' "$d/upload.json" >/dev/null 2>&1 || continue
      # keep the most recently modified qualifying dir
      if [[ -z "$prev_artifacts" || "$d" -nt "$prev_artifacts" ]]; then
        prev_artifacts="$d"
      fi
    done
    [[ -z "$prev_artifacts" ]] && log "resume requested but no complete previous artifacts found — full upload"
  fi

  # Recovery mode: stage only the recovered files so the upload/verify pass does
  # not re-hash the whole archive (already-uploaded photos stay untouched).
  local upload_dir="$gp_dir"
  if (( REPROCESS_RECOVERY )); then
    upload_dir="$WORK_DIR/.recovery-upload.$$"
    mkdir -p "$upload_dir"
    local staged=0 rel src
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      src="$gp_dir/$rel"
      if is_raw "$rel" && [[ -f "$gp_dir/${rel%.*}.jpg" ]]; then
        src="$gp_dir/${rel%.*}.jpg"
      fi
      [[ -f "$src" ]] || { log "  WARN: recovery file not found: $rel"; continue; }
      cp -p "$src" "$upload_dir/"
      staged=$((staged + 1))
    done < "$RECOVERY_FILTER"
    log "recovery: staged $staged file(s) for upload"
    if (( staged == 0 )); then
      err "no recoverable files staged — aborting recovery for this archive"
      rm -rf "$upload_dir"
      return 1
    fi
  fi

  if (( ALBUMS_ONLY )); then
    run_mode="albums-only"
    log "albums-only mode: skipping upload/verify"
    log "fetching photos timeline (sha1 index) ..."
    "$CLI" photo timeline -d --json > "$timeline_json" 2>"$artifacts/timeline.err"; rc=$?
    if (( rc != 0 )); then
      err "photo timeline failed (rc=$rc)"; return 1
    fi
    build_timeline_index "$timeline_json" "$timeline_base"
    if [[ ! -s "$timeline_base.sha1" ]]; then
      err "timeline index is empty — invalid timeline response?"; return 1
    fi
    log "timeline indexed: $(wc -l < "$timeline_base.sha1" | tr -d ' ') unique sha1s"

  elif [[ -n "$prev_artifacts" ]] && (( REPROCESS_RECOVERY == 0 )); then
    run_mode="resume"
    log "resume mode: reusing upload + timeline artifacts from $prev_artifacts"
    upload_json="$prev_artifacts/upload.json"
    timeline_base="$prev_artifacts/timeline-index"
    transferred=$(jq '.transferredItems' "$upload_json")
    skipped=$(jq '.skippedItems' "$upload_json")
    failed=$(jq '.failedItems' "$upload_json")
    log "upload summary: transferred=$transferred skipped=$skipped failed=$failed"
    if (( failed > 0 )); then
      err "cached upload reported $failed failures — re-run without --resume to retry"
      return 1
    fi

  else
    if (( REPROCESS_RECOVERY )); then
      run_mode="recovery"
    fi
    log "uploading (conflict strategy: skip) ..."
    "$CLI" photo upload --json -c skip "$upload_dir" > "$upload_json" 2>"$artifacts/upload.err"; rc=$?
    if (( rc != 0 )); then
      err "photo upload failed (rc=$rc) — see $artifacts/upload.err"; return 1
    fi
    transferred=$(jq '.transferredItems' "$upload_json")
    skipped=$(jq '.skippedItems' "$upload_json")
    failed=$(jq '.failedItems' "$upload_json")
    log "upload summary: transferred=$transferred skipped=$skipped failed=$failed"
    if (( failed > 0 )); then
      err "upload reported $failed failures: $(jq -c '.failures' "$upload_json")"
      return 1
    fi

    # Verify: re-run upload, everything already present.
    "$CLI" photo upload --json -c skip "$upload_dir" > "$verify_json" 2>"$artifacts/upload-verify.err"; rc=$?
    if (( rc != 0 )); then
      err "verification upload failed (rc=$rc)"; return 1
    fi
    local v_transferred v_failed
    v_transferred=$(jq '.transferredItems' "$verify_json")
    v_failed=$(jq '.failedItems' "$verify_json")
    log "verify upload: transferred=$v_transferred failed=$v_failed (expect 0 transferred)"
    if (( v_failed > 0 )); then
      err "verify upload reported failures: $(jq -c '.failures' "$verify_json")"
      return 1
    fi
    if (( v_transferred > 0 )); then
      log "WARN: verify upload transferred $v_transferred (content dedup mismatch) — sha1 validation is authoritative"
    fi

    # Recovery: the staged dir is no longer needed once the timeline is verified.
    if (( REPROCESS_RECOVERY )); then
      rm -rf "$upload_dir"
    fi

    # Timeline index (sha1 -> uid, name -> uid).
    log "fetching photos timeline (sha1 index) ..."
    "$CLI" photo timeline -d --json > "$timeline_json" 2>"$artifacts/timeline.err"; rc=$?
    if (( rc != 0 )); then
      err "photo timeline failed (rc=$rc)"; return 1
    fi
    build_timeline_index "$timeline_json" "$timeline_base"
    if [[ ! -s "$timeline_base.sha1" ]]; then
      err "timeline index is empty — invalid timeline response?"; return 1
    fi
    log "timeline indexed: $(wc -l < "$timeline_base.sha1" | tr -d ' ') unique sha1s"
  fi

  # Albums-only precondition: the archive must actually be uploaded already.
  # Checked BEFORE validation so a wrong archive doesn't flood the recovery
  # file — if nothing matches the timeline, album rebuilding is pointless.
  if (( ALBUMS_ONLY )) && (( expected_media > 0 )); then
    local found_in_timeline
    found_in_timeline=$(awk -F '\t' 'NR==FNR { seen[$1]=1; next } seen[$1] { c++ } END { print c+0 }' \
      "$timeline_base.sha1" <(jq -r '.media[].sha1' "$manifest_json"))
    if (( found_in_timeline == 0 )); then
      err "albums-only: none of the $expected_media media files are in the Proton timeline — was this archive ever uploaded?"
      return 1
    fi
  fi

  # Validation 1: every media file present in the timeline (non-fatal).
  # In recovery mode, write to a run-local file and reconcile with the global
  # recovery.tsv on success (see reconcile_recovery).
  local rec_target="$RECOVERY_FILE"
  if (( REPROCESS_RECOVERY )); then
    rec_target="$artifacts/recovery-run.tsv"
    : > "$rec_target"
  fi
  validate_media "$manifest_json" "$timeline_base" "$artifacts" "$rec_target" "$base"
  local media_missing=0
  [[ -f "$artifacts/validation-missing.tsv" ]] && media_missing=$(wc -l < "$artifacts/validation-missing.tsv")

  # Albums.
  local albums_json="$artifacts/albums-takeout.json"
  discover_albums "$gp_dir" "$albums_json"
  process_albums "$albums_json" "$timeline_base" "$artifacts" || return 1

  # Validation 2: album membership (non-fatal).
  local album_failures
  album_failures=$(validate_albums "$artifacts/albums.json" "$artifacts/albums-takeout.json" "$timeline_base" "$artifacts") || true
  album_failures=${album_failures:-0}

  # Summary + state + cleanup.
  local raw_converted=0
  [[ -f "$artifacts/raw-conversions.tsv" ]] && raw_converted=$(wc -l < "$artifacts/raw-conversions.tsv")
  local summary="$artifacts/summary.json"
  jq -n \
    --arg archive "$base" \
    --argjson expected_media "$expected_media" \
    --argjson expected_unique "$expected_unique" \
    --argjson transferred "$transferred" \
    --argjson skipped "$skipped" \
    --argjson failed "$failed" \
    --arg mode "$run_mode" \
    --argjson media_missing "$media_missing" \
    --argjson album_failures "$album_failures" \
    --argjson raw_converted "$raw_converted" \
    --argjson albums_processed "$(jq 'length' "$artifacts/albums.json" 2>/dev/null || echo 0)" \
    '{ archive: $archive,
       status: "OK",
       mode: $mode,
       expected_media: $expected_media,
       expected_unique: $expected_unique,
       uploaded_transferred: $transferred,
       uploaded_skipped: $skipped,
       uploaded_failed: $failed,
       media_missing: $media_missing,
       raw_converted: $raw_converted,
       album_failures: $album_failures,
       albums_processed: $albums_processed }' > "$summary"

  log "==== $base: SUCCESS ===="
  if (( KEEP_WORK == 0 )) && (( ALBUMS_ONLY == 0 )); then
    log "cleaning up $extract_dir"
    rm -rf "$extract_dir"
  fi
  mark_done "$base"
  return 0
}

# ---------------------------------------------------------------------------
# Recovery reconciliation: after a successful recovery run, drop the archive's
# old recovery entries and replace them with the ones that are still missing
# (this run's validation output) plus the RAW files that could not be converted.
# ---------------------------------------------------------------------------
reconcile_recovery() {
  local archive_name="$1" artifacts="$2"
  local tmp run_rec="$artifacts/recovery-run.tsv" failed="$artifacts/raw-conversion-failed.tsv"
  tmp=$(mktemp)
  awk -F '\t' -v a="$archive_name" '$3 != a' "$RECOVERY_FILE" > "$tmp" || true
  if [[ -s "$run_rec" ]]; then
    cat "$run_rec" >> "$tmp"
  fi
  if [[ -s "$failed" ]]; then
    cat "$failed" >> "$tmp"
  fi
  sort -u "$tmp" > "$RECOVERY_FILE" && rm -f "$tmp"
  log "recovery reconciliation done — $archive_name still has $(awk -F '\t' -v a="$archive_name" '$3 == a' "$RECOVERY_FILE" | wc -l | tr -d ' ') pending entry(ies)"
}

# ---------------------------------------------------------------------------
# Reprocess mode: read recovery.tsv, re-extract the affected archives, convert
# the recorded RAW files to JPEG, upload, add to albums and clear the resolved
# entries. Only files that actually recovered are removed from recovery.tsv;
# still-missing and failed-conversion entries are preserved.
# ---------------------------------------------------------------------------
reprocess_recovery() {
  local only="${1:-}" only_base=""
  [[ -n "$only" ]] && only_base=$(basename "$only")
  if [[ ! -s "$RECOVERY_FILE" ]]; then
    log "recovery file is empty — nothing to reprocess"
    return 0
  fi
  if [[ -z "$RAW_CONVERTER" ]]; then
    err "--reprocess-recovery needs a RAW converter: install darktable-cli, or dcraw + ImageMagick convert"
    return 1
  fi

  local -a archives=()
  local a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    if [[ -n "$only_base" && "$a" != "$only_base" ]]; then
      continue
    fi
    archives+=("$a")
  done < <(awk -F '\t' '{print $3}' "$RECOVERY_FILE" | sort -u)
  if (( ${#archives[@]} == 0 )); then
    log "no recovery entries for the requested archive(s)"
    return 0
  fi

  local total=${#archives[@]} i archive full filter
  for (( i = 0; i < total; i++ )); do
    archive="${archives[$i]}"
    full="$TAKEOUT_DIR/$archive"
    if [[ ! -f "$full" ]]; then
      err "archive not found for recovery entry: $full"
      continue
    fi
    filter=$(mktemp)
    awk -F '\t' -v a="$archive" '$3 == a { print $4 }' "$RECOVERY_FILE" | sort -u > "$filter"
    RECOVERY_FILTER="$filter"
    log ""
    log "==== recovery: $archive ($(wc -l < "$filter" | tr -d ' ') entry/entries) ===="
    if run_archive "$full" "$((i + 1))" "$total"; then
      reconcile_recovery "$archive" "$LOG_DIR/run-$RUN_TS/$archive"
    else
      err "recovery run failed for $archive — entries kept in recovery.tsv"
    fi
    rm -f "$filter"
    RECOVERY_FILTER=""
  done
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local mode="import" force=0 only=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      check|--check) mode="check" ;;
      --force) force=1 ;;
      --keep-work) KEEP_WORK=1 ;;
      --resume) RESUME=1 ;;
      --albums-only) ALBUMS_ONLY=1 ;;
      --convert-raw) CONVERT_RAW=1 ;;
      --reprocess-recovery) REPROCESS_RECOVERY=1; CONVERT_RAW=1 ;;
      --archive) shift; only="${1:-}"; [[ -z "$only" ]] && { err "--archive requires a name"; return 2; } ;;
      *) err "unknown option: $1"; usage; return 2 ;;
    esac
    shift
  done

  # Detect the RAW converter once at startup (needed by --convert-raw and
  # --reprocess-recovery).
  RAW_CONVERTER=$(detect_raw_converter)

  RUN_TS=$(date +%Y%m%d-%H%M%S)
  RUN_LOG="$LOG_DIR/import-$RUN_TS.log"
  mkdir -p "$LOG_DIR"
  touch "$RUN_LOG"

  log "gphoto2proton-import: takeout=$TAKEOUT_DIR work=$WORK_DIR logs=$LOG_DIR state=$STATE_DIR"
  log "CLI=$CLI credentials_store=$PROTON_DRIVE_CREDENTIALS_STORE"
  if (( CONVERT_RAW )); then
    if [[ -n "$RAW_CONVERTER" ]]; then
      log "RAW conversion: ON ($RAW_CONVERTER)"
    else
      log "WARN: RAW conversion requested but no converter found (need darktable-cli, or dcraw+convert)"
    fi
  fi
  if (( RESUME )) && (( ALBUMS_ONLY )); then
    log "WARN: --resume ignored in --albums-only mode"
  fi

  if ! preflight; then return 1; fi

  if [[ "$mode" == "check" ]]; then
    check_mode
    return $?
  fi

  # Lock: prevent concurrent runs.
  exec 9>"$STATE_DIR/import.lock"
  if ! flock -n 9; then
    err "another import is already running"
    return 1
  fi

  # Recovery mode reads its own archive list from recovery.tsv.
  if (( REPROCESS_RECOVERY )); then
    reprocess_recovery "$only"
    return $?
  fi

  # Archive selection.
  local -a archives=()
  local f a
  if [[ -n "$only" ]]; then
    if [[ -f "$only" ]]; then
      archives+=("$only")
    elif [[ -f "$TAKEOUT_DIR/$only" ]]; then
      archives+=("$TAKEOUT_DIR/$only")
    else
      err "archive not found: $only"; return 2
    fi
  else
    for f in "$TAKEOUT_DIR"/*.tgz; do
      [[ -f "$f" ]] || continue
      archives+=("$f")
    done
  fi
  if (( ${#archives[@]} == 0 )); then
    err "no takeout archives found in $TAKEOUT_DIR"
    return 1
  fi

  # Sort, drop done ones (unless --force).
  mapfile -t archives < <(printf '%s\n' "${archives[@]}" | sort)
  local -a todo=()
  for a in "${archives[@]}"; do
    # --albums-only manages albums for already-imported archives, so it must
    # reprocess entries that are marked as done.
    if (( force == 0 )) && (( ALBUMS_ONLY == 0 )) && is_done "$(basename "$a")"; then
      log "skipping $(basename "$a") (already done)"
      continue
    fi
    todo+=("$a")
  done
  if (( ${#todo[@]} == 0 )); then
    log "nothing to do — all archives already imported (use --force to redo)"
    return 0
  fi

  local total=${#todo[@]} i archive
  for (( i = 0; i < total; i++ )); do
    archive="${todo[$i]}"
    if ! run_archive "$archive" "$((i + 1))" "$total"; then
      log "run aborted after failure in $(basename "$archive") — log: $RUN_LOG"
      log "artifacts: $LOG_DIR/run-$RUN_TS/$(basename "$archive")"
      return 1
    fi
  done

  log "all archives imported successfully — log: $RUN_LOG"
  return 0
}

main "$@"
