#!/usr/bin/env bash
#
# gphoto2-album-check.sh
#
# Compare album membership between Google Photos (from Takeout metadata) and
# Proton Photos. Reads albums-takeout.json files produced during import for the
# *expected* member set, then queries the live Proton Drive API via the
# `proton-drive` CLI for the *actual* member set, and diffs them.
#
# Members are matched by filename basename (extension-insensitive), so photos
# converted during import (e.g. NEF -> JPG by --convert-raw) still align.
#
# Authentication: same as gphoto2proton-import.sh — uses the `pass` secret
# store via PROTON_DRIVE_CREDENTIALS_STORE=pass. Run `proton-drive auth login`
# if the session is lost.
#
# Platform: Linux. Must run where import logs and `proton-drive` CLI reside.
#
# Usage:
#   gphoto2-album-check.sh [options] [album-name-filter]
#
# Options:
#   --missing      Only show albums where membership is NOT aligned
#   --verbose      Also list individual member files (matched and missing)
#   --list-albums  List all albums found on both sides (fast, no deep check)
#   --json         Output results as JSON (machine-readable)
#   --cached-run TS  Use cached data from a previous run (e.g. 20260803-215915)
#                    instead of querying the live Proton CLI. Useful when the
#                    import is in progress and the CLI is busy.
#   -h, --help     Show this help
#
# Environment:
#   LOG_DIR       $HOME/gphoto2proton/logs
#   STATE_DIR     $HOME/gphoto2proton/state
#   CLI           proton-drive
#
# Examples:
#   ./gphoto2-album-check.sh                          # Check all albums
#   ./gphoto2-album-check.sh "Mercatini"              # Filter by name
#   ./gphoto2-album-check.sh --missing                # Only issues
#   ./gphoto2-album-check.sh --missing --verbose       # Issues with details
#   ./gphoto2-album-check.sh --list-albums             # Fast overview
#   ./gphoto2-album-check.sh --json "Mercatini"        # JSON output
# ============================================================================

set -o pipefail
shopt -s nullglob

# ---- defaults ---------------------------------------------------------------
CLI="${CLI:-proton-drive}"
LOG_DIR="${LOG_DIR:-$HOME/gphoto2proton/logs}"
STATE_DIR="${STATE_DIR:-$HOME/gphoto2proton/state}"
export PROTON_DRIVE_CREDENTIALS_STORE="${PROTON_DRIVE_CREDENTIALS_STORE:-pass}"

MODE_MISSING=0
MODE_VERBOSE=0
MODE_LIST=0
MODE_JSON=0
CACHED_RUN=""
ALBUM_FILTER=""

# ---- helpers ----------------------------------------------------------------
err() { echo "ERROR: $*" >&2; }
warn() { echo "WARN: $*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //; s/^#$//'
  exit 0
}

# ---- parse args -------------------------------------------------------------
while (( $# > 0 )); do
  case "$1" in
    --missing)      MODE_MISSING=1; shift ;;
    --verbose)      MODE_VERBOSE=1; shift ;;
    --list-albums)  MODE_LIST=1; shift ;;
    --json)         MODE_JSON=1; shift ;;
    --cached-run)   CACHED_RUN="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *)              ALBUM_FILTER="$1"; shift ;;
  esac
done

# ---- auth check (skip in cached mode) --------------------------------------
CACHE_DIR=""
if [[ -n "$CACHED_RUN" ]]; then
  CACHE_DIR="$LOG_DIR/run-$CACHED_RUN"
  if [[ ! -d "$CACHE_DIR" ]]; then
    err "cached run directory not found: $CACHE_DIR"
    exit 1
  fi
  warn "using cached data from run-$CACHED_RUN (live Proton CLI not queried)"
else
  "$CLI" album list --json >/dev/null 2>/dev/null || {
    err "proton-drive is not authenticated. Run: $CLI auth login"
    exit 1
  }
fi

# =============================================================================
# STEP 1 — Collect expected album members from albums-takeout.json files
# =============================================================================
declare -A EXPECTED_JSON  # album name -> JSON array of {filename, sha1}
declare -A TAKE_SRC       # album name -> archive name

collect_takeout() {
  local d aj archive_name name members line
  for d in "$LOG_DIR"/run-*/; do
    [[ -d "$d" ]] || continue
    for aj in "$d"/*/albums-takeout.json; do
      [[ -f "$aj" ]] || continue
      archive_name=$(basename "$(dirname "$aj")")
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        name=$(jq -r '.name' <<< "$line")
        members=$(jq -c '[.members[] | {filename, sha1}]' <<< "$line")
        [[ -z "$name" ]] && continue
        if [[ -n "${EXPECTED_JSON[$name]}" ]]; then
          EXPECTED_JSON["$name"]=$(jq -s 'add' <<< "${EXPECTED_JSON[$name]}"$'\n'"$members")
        else
          EXPECTED_JSON["$name"]="$members"
          TAKE_SRC["$name"]="$archive_name"
        fi
      done < <(jq -c '.[]' "$aj" 2>/dev/null)
    done
  done
}

collect_takeout
TAKEOUT_COUNT=${#EXPECTED_JSON[@]}

# =============================================================================
# STEP 2 — Fetch Proton albums
# =============================================================================
if [[ -n "$CACHED_RUN" ]]; then
  PROTON_JSON="[]"
  for aj in "$CACHE_DIR"/*/albums-existing.json; do
    [[ -f "$aj" ]] || continue
    parsed=$(jq -c '[.[] | {uid, name: .name.value}]' "$aj" 2>/dev/null) || continue
    PROTON_JSON=$(jq -n --argjson a "$PROTON_JSON" --argjson b "$parsed" '$a + $b')
  done
  for pj in "$STATE_DIR"/progress/*.json; do
    [[ -f "$pj" ]] || continue
    while IFS=$'\t' read -r pname puid; do
      [[ -z "$pname" ]] && continue
      if ! jq -e --arg n "$pname" '.[] | select(.name == $n) | any' <<< "$PROTON_JSON" >/dev/null 2>&1; then
        PROTON_JSON=$(jq --arg n "$pname" --arg u "$puid" '. + [{uid: $u, name: $n}]' <<< "$PROTON_JSON")
      fi
    done < <(jq -r '.albums[] | "\(.name)\t\(.uid)"' "$pj" 2>/dev/null)
  done
else
  PROTON_JSON=$("$CLI" album list --json 2>/dev/null) || {
    err "album list failed"; exit 1
  }
fi
PROTON_COUNT=$(jq 'length' <<< "$PROTON_JSON")

declare -A P_UID P_NAME
while IFS=$'\t' read -r puid pname; do
  P_UID["$pname"]="$puid"
  P_NAME["$puid"]="$pname"
done < <(jq -r '.[] | "\(.uid)\t\(.name.value)"' <<< "$PROTON_JSON" 2>/dev/null)

# ---- --list-albums fast path -------------------------------------------------
list_albums() {
  if (( MODE_JSON )); then
    jq -n --argjson tc "$TAKEOUT_COUNT" --argjson pc "$PROTON_COUNT" \
      '{takeout_albums: $tc, proton_albums: $pc}'
  else
    echo "=== Google Photos (from Takeout): $TAKEOUT_COUNT albums ==="
    for name in "${!EXPECTED_JSON[@]}"; do
      echo "  [$(jq 'length' <<< "${EXPECTED_JSON[$name]}")] $name"
    done | sort
    echo ""
    echo "=== Proton Photos: $PROTON_COUNT albums ==="
    jq -r '.[] | "  [\(.uid[:8])] \(.name.value)"' <<< "$PROTON_JSON" 2>/dev/null | sort
  fi
  exit 0
}
if (( MODE_LIST )); then list_albums; fi

# =============================================================================
# STEP 3 — Compare albums
# =============================================================================
# build union of album names from both sides, filtered early for performance
ALL_NAMES=()
for n in "${!EXPECTED_JSON[@]}"; do
  [[ -n "$ALBUM_FILTER" ]] && ! grep -qi "$ALBUM_FILTER" <<< "$n" && continue
  ALL_NAMES+=("$n")
done
for n in "${!P_UID[@]}"; do
  [[ -n "$ALBUM_FILTER" ]] && ! grep -qi "$ALBUM_FILTER" <<< "$n" && continue
  skip=0
  for e in "${ALL_NAMES[@]}"; do [[ "$e" == "$n" ]] && skip=1 && break; done
  (( skip == 0 )) && ALL_NAMES+=("$n")
done
IFS=$'\n' ALL_NAMES=($(sort -u <<< "${ALL_NAMES[*]}")); unset IFS

# --cached-run: pre-build uid → album-photos file mapping for fast lookup
declare -A CACHED_PHOTO_FILE
if [[ -n "$CACHED_RUN" ]]; then
  for ap in "$CACHE_DIR"/*/album-photos-*.json; do
    [[ -f "$ap" ]] || continue
    uid_from_file=$(basename "$ap" | sed 's/^album-photos-//; s/\.json$//')
    CACHED_PHOTO_FILE["$uid_from_file"]="$ap"
  done
fi

# output accumulators for JSON mode
JSON_RESULTS="["
JSON_FIRST=1

check_album() {
  local name="$1"
  local exp="${EXPECTED_JSON[$name]:-}"
  local puid="${P_UID[$name]:-}"

  [[ -n "$ALBUM_FILTER" ]] && ! grep -qi "$ALBUM_FILTER" <<< "$name" && return

  # expected members: unique by filename basename (extension-insensitive), so
  # photos converted during import (NEF -> JPG) still align. Raw member count
  # may include duplicates across repeated import runs; display unique figure.
  local e_cnt=0 e_raw=0 e_keys="[]" key_lookup="{}"
  if [[ -n "$exp" ]]; then
    e_raw=$(jq 'length' <<< "$exp")
    e_keys=$(jq '[.[] | select(.filename != null and .filename != "") | .filename] | unique | map(split("/") | last | sub("\\.[^.]*$";"") | ascii_downcase) | unique' <<< "$exp" 2>/dev/null || echo "[]")
    e_cnt=$(jq 'length' <<< "$e_keys")
    key_lookup=$(jq '[.[] | select(.filename != null and .filename != "") | .filename] | unique | map({key: (split("/") | last | sub("\\.[^.]*$";"") | ascii_downcase), value: .}) | group_by(.key) | map(.[0]) | from_entries' <<< "$exp" 2>/dev/null || echo "{}")
  fi

  # ----- Missing on Proton ---------------------------------------------------
  if [[ -z "$puid" ]]; then
    if (( MODE_MISSING )) && (( e_cnt == 0 )); then return; fi
    if (( MODE_JSON )); then
      local line
      line=$(printf '{"name":"%s","expected":%d,"actual":0,"status":"missing_on_proton","missing":%d,"missing_files":[],"extra":0,"extra_files":[],"takeout_archive":"%s"}' \
        "$name" "$e_cnt" "$e_cnt" "${TAKE_SRC[$name]:-}")
      if (( JSON_FIRST )); then JSON_FIRST=0; else JSON_RESULTS+=","; fi
      JSON_RESULTS+="$line"
    else
      echo ""
      echo "  [!!] $name"
      echo "        Expected: $e_cnt members (from Google Takeout)"
      echo "        Proton:   ALBUM NOT FOUND"
      echo "        Status:   MISSING ON PROTON"
    fi
    ((SUM_MISS_PRO++)) || true
    return
  fi

  # ----- Fetch actual members from Proton ------------------------------------
  local actual
  if [[ -n "$CACHED_RUN" ]]; then
    local cached_file="${CACHED_PHOTO_FILE[$puid]:-}"
    if [[ -n "$cached_file" ]]; then
      actual=$(cat "$cached_file")
    else
      actual="[]"
      warn "no cached album-photos for \"$name\" (uid=$puid) in run-$CACHED_RUN"
    fi
  else
    actual=$("$CLI" album photos -d --json "/albums/$puid" 2>/dev/null) || {
      warn "album photos failed for \"$name\" (uid=$puid)"
      return
    }
  fi

  local a_cnt a_keys akey_lookup
  a_cnt=$(jq 'length' <<< "$actual")
  a_keys=$(jq '[.[] | select(.name.value != null) | .name.value] | unique | map(split("/") | last | sub("\\.[^.]*$";"") | ascii_downcase) | unique' <<< "$actual" 2>/dev/null || echo "[]")
  akey_lookup=$(jq '[.[] | select(.name.value != null) | .name.value] | unique | map({key: (split("/") | last | sub("\\.[^.]*$";"") | ascii_downcase), value: .}) | group_by(.key) | map(.[0]) | from_entries' <<< "$actual" 2>/dev/null || echo "{}")

  local miss_json extra_json miss_cnt=0 extra_cnt=0
  miss_json=$(jq -cn --argjson e "$e_keys" --argjson a "$a_keys" \
    '[$e[] | select(. as $x | $a | index($x) | not) | {key: .}]' 2>/dev/null || echo "[]")
  extra_json=$(jq -cn --argjson a "$a_keys" --argjson e "$e_keys" \
    '[$a[] | select(. as $x | $e | index($x) | not) | {key: .}]' 2>/dev/null || echo "[]")
  miss_cnt=$(jq 'length' <<< "$miss_json" 2>/dev/null)
  extra_cnt=$(jq 'length' <<< "$extra_json" 2>/dev/null)

  local is_ok=0
  (( miss_cnt == 0 && extra_cnt == 0 )) && is_ok=1

  if (( MODE_MISSING )) && (( is_ok )); then return; fi

  # ---- resolve filenames ----------------------------------------------------
  local miss_files="[]"
  if (( miss_cnt > 0 )); then
    miss_files=$(jq -n --argjson m "$miss_json" --argjson l "$key_lookup" \
      '[$m[] | {key: .key, filename: ($l[.key] // "unknown")}]' 2>/dev/null || echo "[]")
  fi

  local extra_files="[]"
  if (( extra_cnt > 0 )); then
    extra_files=$(jq -n --argjson x "$extra_json" --argjson l "$akey_lookup" \
      '[$x[] | {key: .key, filename: ($l[.key] // "unknown")}]' 2>/dev/null || echo "[]")
  fi

  # ---- JSON output ----------------------------------------------------------
  if (( MODE_JSON )); then
    local st=$( (( is_ok )) && echo '"ok"' || echo '"mismatch"' )
    local line
    line=$(printf '{"name":"%s","expected":%d,"actual":%d,"status":%s,"missing":%d,"extra":%d,"takeout_archive":"%s"}' \
      "$name" "$e_cnt" "$a_cnt" "$st" "$miss_cnt" "$extra_cnt" "${TAKE_SRC[$name]:-}")
    if (( JSON_FIRST )); then JSON_FIRST=0; else JSON_RESULTS+=","; fi
    JSON_RESULTS+="$line"
    return
  fi

  # ---- Human output ---------------------------------------------------------
  if (( is_ok )); then
    echo ""
    echo "  [OK] $name: $a_cnt/$e_cnt members"
    ((SUM_OK++)) || true
    return
  fi

  echo ""
  echo "  [!!] $name: $a_cnt/$e_cnt members"
  echo "       Missing: $miss_cnt  |  Extra: $extra_cnt"

  if (( MODE_VERBOSE && miss_cnt > 0 )); then
    echo "       Missing files (basename -> takeout filename):"
    jq -r '.[] | "         \(.key) -> \(.filename)"' <<< "$miss_files" 2>/dev/null | head -20
    local mmore
    mmore=$(jq 'length' <<< "$miss_files" 2>/dev/null)
    (( mmore > 20 )) && echo "         ... and $((mmore - 20)) more"
  fi
  if (( MODE_VERBOSE && extra_cnt > 0 )); then
    echo "       Extra files (basename -> proton filename):"
    jq -r '.[] | "         \(.key) -> \(.filename)"' <<< "$extra_files" 2>/dev/null | head -20
    local emore
    emore=$(jq 'length' <<< "$extra_files" 2>/dev/null)
    (( emore > 20 )) && echo "         ... and $((emore - 20)) more"
  fi
  ((SUM_MIS++)) || true
}

# ---- accumulators for summary ----------------------------------------------
SUM_OK=0
SUM_MIS=0
SUM_MISS_PRO=0

for n in "${ALL_NAMES[@]}"; do check_album "$n"; done

# ---- emit JSON --------------------------------------------------------------
if (( MODE_JSON )); then
  JSON_RESULTS+="]"
  jq -n --argjson r "$JSON_RESULTS" \
    --argjson tc "$TAKEOUT_COUNT" \
    --argjson pc "$PROTON_COUNT" \
    '{
      summary: {
        takeout_albums: $tc,
        proton_albums: $pc,
        ok:       ([$r[] | select(.status == "ok")] | length),
        mismatched: ([$r[] | select(.status == "mismatch")] | length),
        missing_on_proton: ([$r[] | select(.status == "missing_on_proton")] | length),
        total_missing_members: ([$r[] | .missing] | add // 0),
        total_extra_members:   ([$r[] | .extra]   | add // 0)
      },
      albums: $r
    }' 2>/dev/null || echo "$JSON_RESULTS"
  exit 0
fi

# ---- human Summary ----------------------------------------------------------
echo ""
echo "========== SUMMARY =========="
echo "  Total compared: $((SUM_OK + SUM_MIS + SUM_MISS_PRO))"
echo "  Aligned (OK):   $SUM_OK"
echo "  Mismatched:     $SUM_MIS"
echo "  Missing Proton: $SUM_MISS_PRO"
echo "============================="