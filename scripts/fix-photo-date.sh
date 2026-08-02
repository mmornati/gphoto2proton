#!/usr/bin/env bash
#
# fix-photo-date.sh
#
# Fix the capture time of already-uploaded Proton Photos that have the wrong
# date (typically videos whose takeout sidecar was missing, so the CLI fell
# back to the archive extraction timestamp instead of the original recording
# date).
#
# For each photo: find it in the timeline, download the original bytes,
# verify content (sha1), adjust the filesystem mtime, persist a state file,
# trash + permanently delete the old copy, re-upload (CLI reads the new mtime
# as the capture time for videos), verify the new capture time, and restore
# album membership.
#
# Safety: the downloaded file and a state file (uid, albums, sha1, target
# date) are kept in $LOG_DIR/fix-work-<run>/ until the photo is FULLY fixed.
# Any failure leaves them in place for manual recovery; nothing is lost.
#
# Timezone: naive datetimes are interpreted in the SERVER's timezone (the
# date matters more than the exact time here). Override with TZ=... if needed.
# Requires Linux (GNU date/coreutils).
#
# Input: a TSV file with two columns per line:
#   <filename>\t<date_or_timestamp>
#
# Supported date formats:
#   Unix epoch seconds    1476540000        (9-11 digits)
#   ISO datetime          2016-10-15 16:37:23  or  2016-10-15T16:37:23
#   Compact datetime      20161015 163723   (date + time separated by space)
#   Compact               20161015          (time defaults to 12:00:00)
#   Date only             2016-10-15        (time defaults to 12:00:00)
#
# Usage:
#   fix-photo-date.sh --file fixes.tsv [--dry-run] [--yes]
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

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$RUN_LOG"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" | tee -a "$RUN_LOG" >&2; }

usage() {
  cat <<'EOF'
Fix capture time of already-uploaded Proton Photos (Linux, proton-drive CLI).

Usage:
  fix-photo-date.sh -f fixes.tsv [--dry-run] [--yes]

Options:
  -f, --file     TSV input file (filename<TAB>date) — required
  -n, --dry-run  Read-only: show what would be done
  -y, --yes      Skip confirmation prompt
  -h, --help     Show this help

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
# Timeline queries (jq-internal limiting; no `| head` → no SIGPIPE/pipefail).
# ---------------------------------------------------------------------------
count_matches() {
  local timeline_json="$1" filename="$2"
  jq --arg f "$filename" '[.[] | select(.name.ok == true and .name.value == $f)] | length' "$timeline_json"
}

photo_field() { # field-expr builder for the first name match
  local timeline_json="$1" filename="$2" expr="$3"
  # shellcheck disable=SC2154  # $f is a jq --arg variable, not bash
  jq -r --arg f "$filename" "
    first(.[] | select(.name.ok == true and .name.value == \$f)) // empty | $expr
  " "$timeline_json"
}

albums_csv_for() {
  local timeline_json="$1" filename="$2"
  jq -r --arg f "$filename" '
    first(.[] | select(.name.ok == true and .name.value == $f)) // empty |
    ((.photo.albums // []) | map(if type == "object" then (.uid // "") else . end) | map(select(. != "")) | join(","))
  ' "$timeline_json"
}

new_uid_by_sha1() { # exclude old uid; newest by creationTime
  local timeline_json="$1" sha1="$2" old_uid="$3"
  jq -r --arg s "$sha1" --arg old "$old_uid" '
    [.[] | select(.activeRevision.claimedDigests.sha1 == $s and .uid != $old)]
    | sort_by(.creationTime) | last | .uid // empty
  ' "$timeline_json"
}

capture_time_of() {
  local timeline_json="$1" uid="$2"
  jq -r --arg u "$uid" 'first(.[] | select(.uid == $u)) // empty | (.photo.captureTime // "")' "$timeline_json"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  local missing=()
  local b
  for b in "$CLI" jq date sha1sum touch find awk; do
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

  mkdir -p "$LOG_DIR"
  RUN_TS=$(date +%Y%m%d-%H%M%S)
  RUN_LOG="$LOG_DIR/fix-photo-date-$RUN_TS.log"
  WORK_DIR="$LOG_DIR/fix-work-$RUN_TS"
  touch "$RUN_LOG"
  trap on_interrupt INT TERM

  log "fix-photo-date: file=$file log=$RUN_LOG work=$WORK_DIR"
  preflight || return 1

  # --- Read TSV (trim names, strip CR, dedupe, tolerate missing trailing \n).
  local -a filenames=() date_inputs=()
  local line_num=0 fn dt rest
  declare -A seen_names=()
  while IFS=$'\t' read -r fn dt rest || [[ -n "${fn:-}" ]]; do
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
    if [[ -n "${rest:-}" ]]; then
      log "WARN: line $line_num: unexpected extra column(s) ignored for \"$fn\""
    fi
    if [[ -z "${dt:-}" ]]; then
      err "line $line_num: missing date for \"$fn\" — skipping"
      continue
    fi
    filenames+=("$fn")
    date_inputs+=("$dt")
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

  # --- Prefetch timeline ONCE; precheck for missing/duplicate names (F3).
  local timeline_pre="$LOG_DIR/.timeline-pre-$$.json"
  if ! "$CLI" photo timeline -d --json > "$timeline_pre" 2>/dev/null; then
    err "timeline fetch failed (preflight)"; rm -f "$timeline_pre"; return 1
  fi
  declare -A skip_entry=()
  local precheck_bad=0 nmatch
  for (( i = 0; i < ${#filenames[@]}; i++ )); do
    nmatch=$(count_matches "$timeline_pre" "${filenames[$i]}")
    if (( nmatch == 0 )); then
      err "precheck: \"${filenames[$i]}\" not found in timeline — skipping"
      skip_entry[$i]=1; precheck_bad=$((precheck_bad + 1))
    elif (( nmatch > 1 )); then
      err "precheck: $nmatch photos named \"${filenames[$i]}\" — ambiguous, aborting this entry (disambiguate manually)"
      skip_entry[$i]=1; precheck_bad=$((precheck_bad + 1))
    fi
  done
  if (( precheck_bad > 0 )); then
    log "precheck: $precheck_bad/${#filenames[@]} entries skipped (not found or ambiguous)"
  fi

  if (( DRY_RUN == 0 && YES == 0 )); then
    echo ""
    echo "This will fix photo(s) for each valid entry. Each photo will be:"
    echo "  - Downloaded from Proton (kept in $WORK_DIR until fully fixed)"
    echo "  - Modified offline (mtime adjusted)"
    echo "  - Deleted from Proton (trash + permanent delete)"
    echo "  - Re-uploaded with the correct capture time (verified)"
    echo "  - Re-added to its original albums (verified)"
    echo ""
    local confirm=""
    read -r -p "Proceed? [y/N] " confirm || confirm=""
    [[ "$confirm" =~ ^[yY] ]] || { log "cancelled"; rm -f "$timeline_pre"; return 0; }
  fi

  mkdir -p "$WORK_DIR"
  local total=${#filenames[@]} fix_ok=0 fix_fail=0 fix_partial=0

  for (( i = 0; i < total; i++ )); do
    if [[ -n "${skip_entry[$i]:-}" ]]; then continue; fi
    local fn="${filenames[$i]}" norm="${norm_dates[$i]}" target_epoch="${target_epochs[$i]}"
    local touch_fmt
    touch_fmt=$(to_touch_format "$norm") || { err "cannot build touch format for \"$norm\""; fix_fail=$((fix_fail+1)); continue; }
    log "[$((i+1))/$total] ==== $fn → $norm ===="

    # Lookup in prefetched timeline.
    local uid sha1_before albums_csv capture_before
    uid=$(photo_field "$timeline_pre" "$fn" ".uid")
    albums_csv=$(albums_csv_for "$timeline_pre" "$fn")
    sha1_before=$(photo_field "$timeline_pre" "$fn" "(.activeRevision.claimedDigests.sha1 // \"\")")
    capture_before=$(photo_field "$timeline_pre" "$fn" "(.photo.captureTime // \"\")")

    if [[ -z "$uid" ]]; then
      err "photo \"$fn\" not found in timeline (was it removed since precheck?)"
      fix_fail=$((fix_fail+1)); continue
    fi
    if [[ -z "$sha1_before" ]]; then
      err "photo \"$fn\": no claimed sha1 digest — refusing to proceed (cannot verify re-upload)"
      fix_fail=$((fix_fail+1)); continue
    fi
    log "  uid=$uid albums=${albums_csv:-none}"
    log "  current captureTime: $capture_before  sha1=$sha1_before"

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
    fi

    if (( DRY_RUN )); then
      log "  DRY RUN: would download, fix mtime to $norm, trash, delete, re-upload, re-add albums (${albums_csv:-none})"
      continue
    fi

    # --- Download into a dedicated, artifact-free subdir (F2).
    local dl="$WORK_DIR/dl-$i"
    rm -rf "$dl"; mkdir -p "$dl"
    log "  downloading ..."
    if ! "$CLI" photo download "/photos/$uid" "$dl" > "$WORK_DIR/download-$i.out" 2>&1; then
      err "download failed for $fn (kept work dir: $WORK_DIR)"; fix_fail=$((fix_fail+1)); continue
    fi
    local -a candidates=()
    local cf
    while IFS= read -r -d '' cf; do candidates+=("$cf"); done < <(find "$dl" -type f -print0)
    if (( ${#candidates[@]} != 1 )); then
      err "expected exactly 1 downloaded file in $dl, found ${#candidates[@]} (kept: $dl)"
      fix_fail=$((fix_fail+1)); continue
    fi
    local local_path="${candidates[0]}"

    # --- Integrity: downloaded bytes must match the original sha1 (F14).
    local dl_sha1
    dl_sha1=$(sha1sum "$local_path" | awk '{print $1}')
    if [[ "$dl_sha1" != "$sha1_before" ]]; then
      err "download sha1 mismatch for $fn ($dl_sha1 != $sha1_before) — refusing to destroy original (kept: $dl)"
      fix_fail=$((fix_fail+1)); continue
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

    # --- Locate the new uid by content sha1, excluding the old uid (poll ≤30s).
    local new_uid="" poll=0 timeline_now="$WORK_DIR/timeline-now-$i.json"
    while (( poll < 6 )); do
      sleep 5
      if "$CLI" photo timeline -d --json > "$timeline_now" 2>/dev/null; then
        new_uid=$(new_uid_by_sha1 "$timeline_now" "$sha1_before" "$uid")
        [[ -n "$new_uid" ]] && break
      fi
      poll=$((poll + 1))
    done
    if [[ -z "$new_uid" ]]; then
      err "new uid not found within 30s for $fn — uploaded file preserved at $local_path (state: $state_file)"
      fix_fail=$((fix_fail+1)); continue
    fi
    log "  new uid=$new_uid"

    # --- Verify the new capture time actually matches the target (F13).
    local entry_partial=0 new_capture new_capture_epoch="" cap_delta=""
    new_capture=$(capture_time_of "$timeline_now" "$new_uid")
    if [[ -n "$new_capture" ]]; then
      new_capture_epoch=$(to_epoch "$new_capture" 2>/dev/null || echo "")
    fi
    if [[ -n "$new_capture_epoch" ]]; then
      cap_delta=$(( new_capture_epoch > target_epoch ? new_capture_epoch - target_epoch : target_epoch - new_capture_epoch ))
      if (( cap_delta > 120 )); then
        err "captureTime mismatch for $fn: got $new_capture, target $norm (delta ${cap_delta}s) — photo re-uploaded but date NOT fixed"
        entry_partial=1
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
      local auid add_rc=0 add_ok="" add_out="$WORK_DIR/album-add-$i.json"
      for auid in "${album_uids[@]}"; do
        [[ -z "$auid" ]] && continue
        log "  adding to album $auid ..."
        add_rc=0
        "$CLI" album add-photo --json "/albums/$auid" "/photos/$new_uid" > "$add_out" 2>"$WORK_DIR/album-add-$i.err" || add_rc=$?
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
      rm -rf "$dl" "$timeline_now"
      rm -f "$state_file" "$WORK_DIR/download-$i.out" "$WORK_DIR/trash-$i.out" "$WORK_DIR/delete-$i.out" "$WORK_DIR/upload-$i.json" "$WORK_DIR/upload-$i.err"
      fix_ok=$((fix_ok + 1))
      log "  OK"
    else
      fix_partial=$((fix_partial + 1))
      log "  PARTIAL (kept work files in $WORK_DIR)"
    fi
  done

  rm -f "$timeline_pre"
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
