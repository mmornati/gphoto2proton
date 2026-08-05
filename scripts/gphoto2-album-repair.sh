#!/usr/bin/env bash
#
# gphoto2-album-repair.sh
#
# Repair album membership between Google Photos (from Takeout metadata) and
# Proton Photos. Reads albums-takeout.json files produced during import to
# determine the *expected* member set, then queries the live Proton Photos API
# via the `proton-drive` CLI for the *actual* member set, and adds any missing
# photos to the correct albums. Albums that do not exist on Proton yet are
# created first.
#
# Members are matched by SHA-1 hash (from the Proton timeline index), with
# filename-based fallback for members without a SHA-1. This is the same
# resolution strategy used by gphoto2proton-import.sh.
#
# Authentication: same as gphoto2proton-import.sh — uses the `pass` secret
# store via PROTON_DRIVE_CREDENTIALS_STORE=pass. Run `proton-drive auth login`
# if the session is lost.
#
# Platform: Linux. Must run where import logs and `proton-drive` CLI reside.
#
# Usage:
#   gphoto2-album-repair.sh [options] [album-name-filter]
#
# Options:
#   --dry-run      Preview what would be done without making changes
#   --verbose      Show per-photo details for each album
#   --json         Output results as JSON (machine-readable)
#   -h, --help     Show this help
#
# Environment:
#   LOG_DIR       $HOME/gphoto2proton/logs
#   STATE_DIR     $HOME/gphoto2proton/state
#   CLI           proton-drive
#   CHUNK_SIZE    200
#
# Examples:
#   ./gphoto2-album-repair.sh                              # Fix all albums
#   ./gphoto2-album-repair.sh "Mercatini"                  # Filter by name
#   ./gphoto2-album-repair.sh --dry-run                    # Preview only
#   ./gphoto2-album-repair.sh --dry-run --verbose          # Preview with details
#   ./gphoto2-album-repair.sh --json                       # Machine-readable
# ============================================================================

set -o pipefail
shopt -s nullglob

# ---- defaults ---------------------------------------------------------------
CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
STATE_DIR="${STATE_DIR:-$HOME/gphoto2proton/state}"
CHUNK_SIZE="${CHUNK_SIZE:-200}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

err() { echo "ERROR: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
info() { echo "[$(date +%H:%M:%S)] $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //; s/^#$//'
  exit 0
}

main() {
  # ---- parse args -----------------------------------------------------------
  local MODE_DRY_RUN=0 MODE_VERBOSE=0 MODE_JSON=0 ALBUM_FILTER=""
  while (( $# > 0 )); do
    case "$1" in
      --dry-run)   MODE_DRY_RUN=1; shift ;;
      --verbose)   MODE_VERBOSE=1; shift ;;
      --json)      MODE_JSON=1; shift ;;
      -h|--help)   usage ;;
      *)           ALBUM_FILTER="$1"; shift ;;
    esac
  done

  # ---- auth check -----------------------------------------------------------
  info "checking authentication ..."
  "$CLI" album list --json >/dev/null 2>/dev/null || {
    err "proton-drive is not authenticated. Run: $CLI auth login"
    exit 1
  }

  # ===========================================================================
  # STEP 1 — Collect expected album members from albums-takeout.json files
  # ===========================================================================
  declare -A EXPECTED
  local TAKEOUT_COUNT=0

  collect_takeout() {
    local d aj line name members
    for d in "$LOG_DIR"/run-*/; do
      [[ -d "$d" ]] || continue
      for aj in "$d"/*/albums-takeout.json; do
        [[ -f "$aj" ]] || continue
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          name=$(jq -r '.name' <<< "$line")
          members=$(jq -c '[.members[] | {sha1, filename, size}]' <<< "$line")
          [[ -z "$name" ]] && continue
          if [[ -n "${EXPECTED[$name]}" ]]; then
            EXPECTED["$name"]=$(jq -s 'add' <<< "${EXPECTED[$name]}"$'\n'"$members")
          else
            EXPECTED["$name"]="$members"
          fi
        done < <(jq -c '.[]' "$aj" 2>/dev/null)
      done
    done
  }

  info "collecting expected album members from import logs ..."
  collect_takeout
  TAKEOUT_COUNT=${#EXPECTED[@]}
  info "  found $TAKEOUT_COUNT albums in takeout logs"

  if (( TAKEOUT_COUNT == 0 )); then
    err "no albums found in $LOG_DIR/run-*/*/albums-takeout.json — nothing to repair"
    exit 1
  fi

  # ===========================================================================
  # STEP 2 — Build Proton timeline index (sha1 -> uid, filename -> uid)
  # ===========================================================================
  info "fetching Proton photo timeline ..."
  local TIMELINE_JSON TIMELINE_SHA1 TIMELINE_NAME TIMELINE_COUNT
  TIMELINE_JSON=$(mktemp)
  TIMELINE_SHA1=$(mktemp)
  TIMELINE_NAME=$(mktemp)
  "$CLI" photo timeline -d --json > "$TIMELINE_JSON" 2>/dev/null; local rc=$?
  if (( rc != 0 )); then
    err "photo timeline failed (rc=$rc)"
    rm -f "$TIMELINE_JSON" "$TIMELINE_SHA1" "$TIMELINE_NAME"
    exit 1
  fi

  jq -r '.[] | select(.activeRevision.claimedDigests.sha1 != null) | [.activeRevision.claimedDigests.sha1, .uid] | @tsv' "$TIMELINE_JSON" | sort -u > "$TIMELINE_SHA1"
  jq -r '.[] | select(.name.ok == true) | [.name.value, .uid] | @tsv' "$TIMELINE_JSON" | sort -u > "$TIMELINE_NAME"

  sha1_to_uid() {
    local sha="$1"
    awk -F '\t' -v s="$sha" '$1 == s { print $2; exit }' "$TIMELINE_SHA1"
  }

  name_to_uid() {
    local name="$1"
    awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$TIMELINE_NAME"
  }

  TIMELINE_COUNT=$(wc -l < "$TIMELINE_SHA1" | tr -d ' ')
  info "  timeline indexed: $TIMELINE_COUNT unique sha1s"

  if (( TIMELINE_COUNT == 0 )); then
    err "timeline index is empty — cannot resolve members"
    rm -f "$TIMELINE_JSON" "$TIMELINE_SHA1" "$TIMELINE_NAME"
    exit 1
  fi

  # ===========================================================================
  # STEP 3 — Fetch existing Proton albums
  # ===========================================================================
  info "fetching existing Proton albums ..."
  local PROTON_JSON PROTON_COUNT
  PROTON_JSON=$("$CLI" album list --json 2>/dev/null) || {
    err "album list failed"
    rm -f "$TIMELINE_JSON" "$TIMELINE_SHA1" "$TIMELINE_NAME"
    exit 1
  }
  PROTON_COUNT=$(jq 'length' <<< "$PROTON_JSON")
  info "  $PROTON_COUNT albums on Proton"

  declare -A P_UID
  while IFS=$'\t' read -r puid pname; do
    P_UID["$pname"]="$puid"
  done < <(jq -r '.[] | "\(.uid)\t\(.name.value)"' <<< "$PROTON_JSON" 2>/dev/null)

  # ===========================================================================
  # HELPERS
  # ===========================================================================

  unique_shas() {
    local json="$1"
    jq -r '.[] | select(.sha1 != null and .sha1 != "" and .sha1 != "0") | .sha1' <<< "$json" | sort -u
  }

  dedupe_members() {
    local json="$1"
    jq -c 'group_by(.sha1) | map(.[0])' <<< "$json"
  }

  local JSON_RESULTS="[" JSON_FIRST=1

  emit_json() {
    local obj="$1"
    if (( JSON_FIRST )); then JSON_FIRST=0; else JSON_RESULTS+=","; fi
    JSON_RESULTS+="$obj"
  }

  # ===========================================================================
  # STEP 4 — Repair each album
  # ===========================================================================
  local SUM_CREATED=0 SUM_REPAIRED=0 SUM_OK=0 SUM_ERRORS=0 SUM_ADDED=0
  local -a ALL_NAMES=()
  local name

  for name in "${!EXPECTED[@]}"; do
    [[ -n "$ALBUM_FILTER" ]] && ! grep -qi "$ALBUM_FILTER" <<< "$name" && continue
    ALL_NAMES+=("$name")
  done

  {
    IFS=$'\n' read -r -d '' -a ALL_NAMES < <(printf '%s\n' "${ALL_NAMES[@]}" | sort -u && printf '\0')
  } 2>/dev/null

  info ""
  info "processing ${#ALL_NAMES[@]} albums ..."
  info ""

  for name in "${ALL_NAMES[@]}"; do
    local members_json mem_count puid resolved_count
    members_json="${EXPECTED[$name]}"
    members_json=$(dedupe_members "$members_json")
    mem_count=$(jq 'length' <<< "$members_json")

    if (( mem_count == 0 )); then
      SUM_OK=$((SUM_OK + 1))
      continue
    fi
    if (( mem_count > 10000 )); then
      err "album \"$name\" has $mem_count members (Proton limit is 10000) — skipping"
      SUM_ERRORS=$((SUM_ERRORS + 1))
      continue
    fi

    # Resolve members to Proton UIDs (sha1 -> uid, fallback name -> uid).
    local -a uid_list=()
    local -a seen=()
    local j m_sha1 m_name m_uid dup

    for (( j = 0; j < mem_count; j++ )); do
      m_sha1=$(jq -r --argjson j "$j" '.[$j].sha1' <<< "$members_json")
      m_name=$(jq -r --argjson j "$j" '.[$j].filename' <<< "$members_json")
      m_uid=""
      if [[ -n "$m_sha1" ]] && [[ "$m_sha1" != "0" ]]; then
        m_uid=$(sha1_to_uid "$m_sha1")
      fi
      if [[ -z "$m_uid" ]] && [[ -n "$m_name" ]]; then
        m_uid=$(name_to_uid "$m_name")
      fi
      if [[ -z "$m_uid" ]]; then
        (( MODE_VERBOSE )) && warn "  no timeline match for \"$m_name\" (sha1 ${m_sha1:-none})"
        continue
      fi
      dup=0
      for n in "${seen[@]+"${seen[@]}"}"; do [[ "$n" == "$m_uid" ]] && dup=1 && break; done
      if (( dup == 0 )); then
        seen+=("$m_uid")
        uid_list+=("$m_uid")
      fi
    done

    resolved_count=${#uid_list[@]}
    if (( resolved_count == 0 )); then
      warn "album \"$name\": no members could be matched to the timeline — skipping"
      SUM_ERRORS=$((SUM_ERRORS + 1))
      continue
    fi

    puid="${P_UID[$name]:-}"

    # ---- Album missing on Proton ---------------------------------------------
    if [[ -z "$puid" ]]; then
      if (( MODE_DRY_RUN )); then
        info "  [WOULD CREATE] \"$name\" — $resolved_count members"
        emit_json "$(jq -n --arg n "$name" --argjson r "$resolved_count" \
          '{name: $n, action: "would_create", resolved: $r}')"
        SUM_CREATED=$((SUM_CREATED + 1))
      else
        info "  [CREATE] \"$name\" — $resolved_count members"
        local create_out add_out
        create_out=$("$CLI" album create --json "$name" 2>/dev/null); rc=$?
        if (( rc != 0 )); then
          err "failed to create album \"$name\""
          SUM_ERRORS=$((SUM_ERRORS + 1))
          continue
        fi
        puid=$(jq -r '.uid' <<< "$create_out")
        P_UID["$name"]="$puid"

        local -a photo_paths=()
        for n in "${uid_list[@]}"; do photo_paths+=("/photos/$n"); done
        local total=${#photo_paths[@]} start=0 end=0 ok_total=0 fail_total=0
        while (( start < total )); do
          end=$((start + CHUNK_SIZE)); (( end > total )) && end=$total
          add_out=$("$CLI" album add-photo --json "/albums/$puid" "${photo_paths[@]:start:CHUNK_SIZE}" 2>/dev/null); rc=$?
          if (( rc != 0 )); then
            err "add-photo batch failed (rc=$rc) for \"$name\""
            SUM_ERRORS=$((SUM_ERRORS + 1))
            break
          fi
          local okc failc
          okc=$(jq '[.[] | select(.ok == true)] | length' <<< "$add_out")
          failc=$(jq '[.[] | select(.ok != true)] | length' <<< "$add_out")
          ok_total=$((ok_total + okc)); fail_total=$((fail_total + failc))
          start=$end
        done
        SUM_ADDED=$((SUM_ADDED + ok_total))
        if (( fail_total > 0 )); then
          warn "  album \"$name\": $fail_total member adds failed"
        fi
        SUM_CREATED=$((SUM_CREATED + 1))
        emit_json "$(jq -n --arg n "$name" --argjson r "$resolved_count" --argjson ok "$ok_total" --argjson fail "$fail_total" \
          '{name: $n, action: "created", resolved: $r, added: $ok, failed: $fail}')"
      fi
      continue
    fi

    # ---- Album exists — check for missing members ----------------------------
    local actual_json actual_shas expected_shas
    actual_json=$("$CLI" album photos -d --json "/albums/$puid" 2>/dev/null); rc=$?
    if (( rc != 0 )); then
      err "failed to fetch photos for album \"$name\" (uid=$puid)"
      SUM_ERRORS=$((SUM_ERRORS + 1))
      continue
    fi

    actual_shas=$(jq -r '.[] | select(.activeRevision.claimedDigests.sha1 != null) | .activeRevision.claimedDigests.sha1' <<< "$actual_json" | sort -u)
    expected_shas=$(unique_shas "$members_json")

    local missing_shas missing_count
    missing_shas=$(comm -23 <(printf '%s\n' "$expected_shas") <(printf '%s\n' "$actual_shas") 2>/dev/null)
    missing_count=$(printf '%s\n' "$missing_shas" | grep -c . || true)

    if (( missing_count == 0 )); then
      info "  [OK] \"$name\" — $mem_count members (all present)"
      SUM_OK=$((SUM_OK + 1))
      emit_json "$(jq -n --arg n "$name" --argjson c "$mem_count" \
        '{name: $n, action: "ok", total: $c}')"
      continue
    fi

    # Resolve missing sha1s to UIDs.
    local -a missing_uids=()
    while IFS= read -r sha; do
      [[ -z "$sha" ]] && continue
      m_uid=$(sha1_to_uid "$sha")
      [[ -n "$m_uid" ]] && missing_uids+=("$m_uid")
    done <<< "$missing_shas"

    local missing_resolved=${#missing_uids[@]}
    info "  [REPAIR] \"$name\" — $missing_resolved/$missing_count missing members resolvable"

    if (( missing_resolved == 0 )); then
      warn "  no missing members could be resolved to timeline UIDs for \"$name\""
      SUM_ERRORS=$((SUM_ERRORS + 1))
      continue
    fi

    if (( MODE_VERBOSE )); then
      while IFS= read -r sha; do
        [[ -n "$sha" ]] && info "    missing sha1: $sha"
      done <<< "$missing_shas"
    fi

    if (( MODE_DRY_RUN )); then
      info "    [WOULD ADD] $missing_resolved photos"
      SUM_REPAIRED=$((SUM_REPAIRED + 1))
      emit_json "$(jq -n --arg n "$name" --argjson m "$missing_count" --argjson r "$missing_resolved" \
        '{name: $n, action: "would_repair", missing: $m, resolvable: $r}')"
      continue
    fi

    # Add missing photos.
    local -a photo_paths=()
    for n in "${missing_uids[@]}"; do photo_paths+=("/photos/$n"); done
    local total=${#photo_paths[@]} start=0 end=0 ok_total=0 fail_total=0
    while (( start < total )); do
      end=$((start + CHUNK_SIZE)); (( end > total )) && end=$total
      add_out=$("$CLI" album add-photo --json "/albums/$puid" "${photo_paths[@]:start:CHUNK_SIZE}" 2>/dev/null); rc=$?
      if (( rc != 0 )); then
        err "add-photo batch failed (rc=$rc) for \"$name\""
        SUM_ERRORS=$((SUM_ERRORS + 1))
        break
      fi
      local okc failc
      okc=$(jq '[.[] | select(.ok == true)] | length' <<< "$add_out")
      failc=$(jq '[.[] | select(.ok != true)] | length' <<< "$add_out")
      ok_total=$((ok_total + okc)); fail_total=$((fail_total + failc))
      start=$end
    done
    SUM_ADDED=$((SUM_ADDED + ok_total))
    info "    added $ok_total photos (${fail_total} failures)"
    SUM_REPAIRED=$((SUM_REPAIRED + 1))
    emit_json "$(jq -n --arg n "$name" --argjson m "$missing_count" --argjson r "$missing_resolved" --argjson ok "$ok_total" --argjson fail "$fail_total" \
      '{name: $n, action: "repaired", missing: $m, resolvable: $r, added: $ok, failed: $fail}')"
  done

  # ===========================================================================
  # STEP 5 — Summary
  # ===========================================================================
  JSON_RESULTS+="]"

  if (( MODE_JSON )); then
    jq -n \
      --argjson r "$JSON_RESULTS" \
      --argjson tc "$TAKEOUT_COUNT" \
      --argjson pc "$PROTON_COUNT" \
      --argjson tp "${#ALL_NAMES[@]}" \
      --argjson ok "$SUM_OK" \
      --argjson created "$SUM_CREATED" \
      --argjson repaired "$SUM_REPAIRED" \
      --argjson errors "$SUM_ERRORS" \
      --argjson added "$SUM_ADDED" \
      --arg dry "$MODE_DRY_RUN" \
      '{
        summary: {
          takeout_albums: $tc,
          proton_albums: $pc,
          processed: $tp,
          ok: $ok,
          created: $created,
          repaired: $repaired,
          errors: $errors,
          photos_added: $added,
          dry_run: ($dry == "1")
        },
        albums: $r
      }'
  else
    echo ""
    echo "========== SUMMARY =========="
    echo "  Total albums (takeout): $TAKEOUT_COUNT"
    echo "  Albums on Proton:       $PROTON_COUNT"
    echo "  Processed:              ${#ALL_NAMES[@]}"
    echo "  Already OK:             $SUM_OK"
    echo "  Repaired:               $SUM_REPAIRED"
    echo "  Created:                $SUM_CREATED"
    if (( MODE_DRY_RUN )); then
      echo "  WOULD ADD:              $SUM_ADDED photos"
    else
      echo "  Photos added:           $SUM_ADDED"
    fi
    if (( SUM_ERRORS > 0 )); then
      echo "  Errors:                 $SUM_ERRORS"
    fi
    echo "============================="
    if (( MODE_DRY_RUN )); then
      echo ""
      echo "This was a DRY RUN — no changes were made. Run without --dry-run to apply."
    fi
  fi

  # ---- cleanup --------------------------------------------------------------
  rm -f "$TIMELINE_JSON" "$TIMELINE_SHA1" "$TIMELINE_NAME"

  (( SUM_ERRORS > 0 )) && exit 1
  exit 0
}

main "$@"