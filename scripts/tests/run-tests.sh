#!/usr/bin/env bash
#
# Functional tests for scripts/gphoto2proton-import.sh using a mock
# proton-drive CLI (see mock-proton-drive). Every scenario runs in its own
# fresh temp root and builds its own fixture takeout archive.
#
# Runs natively on Linux. On BSD/macOS it installs tiny GNU-compat shims for
# `stat`/`date`/`flock` (the script targets GNU coreutils) so its logic can be
# exercised on a dev machine.
#
# Usage: scripts/tests/run-tests.sh
#
# shellcheck disable=SC2012  # ls used intentionally for newest log/artifact dir
# shellcheck disable=SC2329  # cleanup() IS invoked via `trap cleanup EXIT`

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT="$SCRIPT_DIR/../gphoto2proton-import.sh"
MOCK="$SCRIPT_DIR/mock-proton-drive"

TESTS_RUN=0
TESTS_FAIL=0
ROOT=""
SHIMS=""
MOCK_LOG=""
MOCK_STORE=""
MOCK_FAIL_ALBUMS=""

cleanup() { [[ -n "${ROOT:-}" ]] && rm -rf "$ROOT"; }
trap cleanup EXIT

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '    ok: %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAIL=$((TESTS_FAIL + 1)); printf '    FAIL: %s\n' "$1" >&2; }

assert_eq() {
  local desc="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then pass "$desc"; else fail "$desc (got: $actual, want: $expected)"; fi
}

assert_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then pass "$desc"; else fail "$desc (pattern: $pattern)"; fi
}

assert_not_grep() {
  local desc="$1" file="$2" pattern="$3"
  if grep -qE -- "$pattern" "$file"; then fail "$desc (pattern: $pattern)"; else pass "$desc"; fi
}

new_root() {
  ROOT=$(mktemp -d /tmp/gphoto2proton-tests.XXXXXX)
  mkdir -p "$ROOT/takeout" "$ROOT/work" "$ROOT/logs" "$ROOT/state" "$ROOT/fixtures"
  MOCK_LOG="$ROOT/mock.log"
  : > "$MOCK_LOG"
  MOCK_STORE="$ROOT/mock-store"
  MOCK_FAIL_ALBUMS=""
  export MOCK_LOG MOCK_STORE
}

# GNU-compat shims for non-Linux hosts (the import script uses stat -c%s,
# date -d @epoch and flock).
setup_shims() {
  if [[ "$(uname -s)" == "Linux" ]]; then
    SHIMS=""
    return 0
  fi
  SHIMS="$ROOT/shims"
  mkdir -p "$SHIMS"

  cat > "$SHIMS/stat" <<'SHIMEOF'
#!/usr/bin/env bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c%s) args+=(-f%z) ;;
    -c%a) args+=(-f%a) ;;
    -c%h) args+=(-f%l) ;;
    -c%i) args+=(-f%i) ;;
    -c%n) args+=(-f%N) ;;
    -c%u) args+=(-f%u) ;;
    -c%g) args+=(-f%g) ;;
    -c%Y) args+=(-f%m) ;;
    *) args+=("$1") ;;
  esac
  shift
done
exec /usr/bin/stat "${args[@]}"
SHIMEOF

  cat > "$SHIMS/date" <<'SHIMEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-d" && "${2:-}" == "@"* ]]; then
  epoch="${2#@}"
  shift 2
  exec /bin/date -r "$epoch" "$@"
fi
exec /bin/date "$@"
SHIMEOF

  cat > "$SHIMS/flock" <<'SHIMEOF'
#!/usr/bin/env perl
use strict; use warnings;
use Fcntl qw(:flock);
my @a = @ARGV;
my $nb = 0;
while (@a && $a[0] =~ /^-/) { $nb = 1 if $a[0] eq '-n'; shift @a; }
my $fd = shift @a;
my $mode = LOCK_EX;
$mode |= LOCK_NB if $nb;
if (open(my $fh, "<&", $fd)) {
  exit(flock($fh, $mode) ? 0 : 1);
}
print STDERR "flock: cannot dup fd $fd: $!\n";
exit 1;
SHIMEOF

  chmod +x "$SHIMS/stat" "$SHIMS/date" "$SHIMS/flock"
}

make_fixture_a() {
  local src="$1"
  mkdir -p "$src/Takeout/Google Photos/Albums/AlbumOne" \
           "$src/Takeout/Google Photos/Albums/AlbumTwo" \
           "$src/Takeout/Google Photos/Loose"
  printf 'photo a1\n' > "$src/Takeout/Google Photos/Albums/AlbumOne/a1.jpg"
  printf 'photo b1\n' > "$src/Takeout/Google Photos/Albums/AlbumOne/b1.jpg"
  printf 'photo c1\n' > "$src/Takeout/Google Photos/Albums/AlbumTwo/c1.jpg"
  printf 'photo x1\n' > "$src/Takeout/Google Photos/Loose/x1.jpg"
  printf '{"photoTakenTime":{"timestamp":"1577836800"}}\n' \
    > "$src/Takeout/Google Photos/Albums/AlbumOne/a1.jpg.supplemental-metadata.json"
  printf 'junk\n' > "$src/Takeout/Google Photos/._junkfile"
  touch "$src/Takeout/Google Photos/.DS_Store"
}

# Old-format takeout: albums are the immediate subdirectories of Google Photos/.
make_fixture_b() {
  local src="$1"
  mkdir -p "$src/Takeout/Google Photos/Trip 2024" \
           "$src/Takeout/Google Photos/Family"
  printf 'photo a2\n' > "$src/Takeout/Google Photos/Trip 2024/a2.jpg"
  printf 'photo b2\n' > "$src/Takeout/Google Photos/Family/b2.jpg"
  printf 'photo r2\n' > "$src/Takeout/Google Photos/root.jpg"
}

make_tgz() {
  local src="$1" tgz="$2"
  (cd "$(dirname "$src")" && tar -czf "$tgz" "$(basename "$src")")
}

run_import() {
  ( cd "$ROOT" && \
    TAKEOUT_DIR="$ROOT/takeout" WORK_DIR="$ROOT/work" LOG_DIR="$ROOT/logs" STATE_DIR="$ROOT/state" \
    CLI="$MOCK" MOCK_FAIL_ALBUMS="$MOCK_FAIL_ALBUMS" \
    PATH="${SHIMS:+$SHIMS:}$PATH" \
    bash "$IMPORT" "$@" >"$ROOT/run.out" 2>&1 )
}

run_import_ok() {
  run_import "$@"
  assert_eq "import exits 0" "$?" "0"
}

run_import_fail() {
  run_import "$@"
  local rc=$?
  if [[ "$rc" == "0" ]]; then
    fail "import exits non-zero (got: $rc)"
  else
    pass "import exits non-zero"
  fi
}

latest_log() { ls -1t "$ROOT"/logs/import-*.log 2>/dev/null | head -1; }
newest_artifacts() { ls -1dt "$ROOT"/logs/run-* 2>/dev/null | head -1; }
mock_count() { grep -cE -- "$1" "$MOCK_LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Scenario 1: full import on a standard (Albums/) takeout.
# ---------------------------------------------------------------------------
t1_full_import() {
  echo "== t1: full import (baseline)"
  new_root
  setup_shims
  make_fixture_a "$ROOT/fixtures/a"
  make_tgz "$ROOT/fixtures/a" "$ROOT/takeout/test-a.tgz"
  run_import_ok --keep-work --archive test-a.tgz

  local art progress log
  art="$(newest_artifacts)/test-a.tgz"
  progress="$ROOT/state/progress/test-a.tgz.json"
  log=$(latest_log)

  assert_eq "summary status OK" "$(jq -r '.status' "$art/summary.json")" "OK"
  assert_eq "expected_media = 4" "$(jq -r '.expected_media' "$art/summary.json")" "4"
  assert_eq "media_missing = 0" "$(jq -r '.media_missing' "$art/summary.json")" "0"
  assert_eq "albums_processed = 2" "$(jq -r '.albums_processed' "$art/summary.json")" "2"
  assert_eq "album_failures = 0" "$(jq -r '.album_failures' "$art/summary.json")" "0"
  assert_eq "2 albums discovered" "$(jq 'length' "$art/albums-takeout.json")" "2"
  assert_eq "2 albums built" "$(jq 'length' "$art/albums.json")" "2"
  assert_eq "done marked" "$(grep -c '^test-a.tgz$' "$ROOT/state/done")" "1"
  assert_eq "steps.junk recorded" "$(jq -r '.steps.junk' "$progress")" "true"
  assert_eq "steps.sidecar_dates recorded" "$(jq -r '.steps.sidecar_dates' "$progress")" "true"
  assert_eq "steps.manifest recorded" "$(jq -r '.steps.manifest' "$progress")" "true"
  assert_eq "steps.upload_verify recorded" "$(jq -r '.steps.upload_verify' "$progress")" "true"
  assert_eq "steps.timeline recorded" "$(jq -r '.steps.timeline' "$progress")" "true"
  assert_eq "steps.validate_media recorded" "$(jq -r '.steps.validate_media' "$progress")" "true"
  assert_eq "validate_albums.count = 2" "$(jq -r '.validate_albums.count' "$progress")" "2"
  assert_eq "timeline fetched once" "$(mock_count '^photo timeline')" "1"
  assert_eq "upload+verify invoked (2 calls)" "$(mock_count '^photo upload')" "2"
  assert_eq "two album creates" "$(mock_count '^album create')" "2"
  assert_grep "junk stripped" "$log" "stripping macOS metadata junk"
  assert_grep "sidecar dates applied" "$log" "applying original capture dates from sidecar JSON"
}

# ---------------------------------------------------------------------------
# Scenario 2: --resume on a completed archive skips every finished step and
# still fetches a fresh timeline.
# ---------------------------------------------------------------------------
t2_resume_skips_steps() {
  echo "== t2: --resume skips completed steps, refreshes timeline"
  new_root
  setup_shims
  make_fixture_a "$ROOT/fixtures/a"
  make_tgz "$ROOT/fixtures/a" "$ROOT/takeout/test-a.tgz"
  run_import_ok --keep-work --archive test-a.tgz

  local before_upload before_timeline before_create before_add
  before_upload=$(mock_count '^photo upload')
  before_timeline=$(mock_count '^photo timeline')
  before_create=$(mock_count '^album create')
  before_add=$(mock_count '^album add-photo')

  run_import_ok --force --resume --keep-work --archive test-a.tgz

  local art progress log
  art="$(newest_artifacts)/test-a.tgz"
  progress="$ROOT/state/progress/test-a.tgz.json"
  log=$(latest_log)

  assert_eq "no new upload calls on resume" "$(mock_count '^photo upload')" "$before_upload"
  assert_eq "exactly one fresh timeline fetch on resume" "$(( $(mock_count '^photo timeline') - before_timeline ))" "1"
  assert_eq "no album creates on resume" "$(mock_count '^album create')" "$before_create"
  assert_eq "no album add-photo on resume" "$(mock_count '^album add-photo')" "$before_add"
  assert_grep "skips junk strip" "$log" "skipping junk strip \(already done\)"
  assert_grep "skips sidecar dates" "$log" "skipping sidecar capture-date application \((already done|upload already complete)\)"
  assert_grep "reuses manifest from previous run" "$log" "reusing manifest from previous run"
  assert_grep "reuses upload counters" "$log" "upload summary \(previous run\): transferred=[0-9]"
  assert_grep "fresh timeline fetched" "$log" "resume mode: fetching fresh photos timeline"
  assert_grep "skips media validation" "$log" "skipping media validation \(already validated in a previous run\)"
  assert_grep "skips albums" "$log" "already processed, skipping"
  assert_grep "skips album validation" "$log" "album membership already validated"
  assert_eq "summary OK" "$(jq -r '.status' "$art/summary.json")" "OK"
  assert_eq "all steps still recorded" "$(jq -r '.steps.upload_verify and .steps.timeline and .steps.validate_media and .steps.manifest' "$progress")" "true"
}

# ---------------------------------------------------------------------------
# Scenario 3: failure mid-way through albums, then --resume continues at the
# failed album without reprocessing the completed one.
# ---------------------------------------------------------------------------
t3_mid_album_failure() {
  echo "== t3: failure mid-albums, resume continues at failed album"
  new_root
  setup_shims
  make_fixture_a "$ROOT/fixtures/a"
  make_tgz "$ROOT/fixtures/a" "$ROOT/takeout/test-a.tgz"
  MOCK_FAIL_ALBUMS="AlbumTwo"
  run_import_fail --keep-work --archive test-a.tgz

  local art progress
  art="$(newest_artifacts)/test-a.tgz"
  progress="$ROOT/state/progress/test-a.tgz.json"
  assert_eq "partial albums.json has 1 album" "$(jq 'length' "$art/albums.json")" "1"
  assert_eq "partial album is AlbumOne" "$(jq -r '.[0].name' "$art/albums.json")" "AlbumOne"
  assert_eq "progress records 1 album" "$(jq '.albums | length' "$progress")" "1"
  assert_eq "upload_verify step recorded" "$(jq -r '.steps.upload_verify' "$progress")" "true"

  MOCK_FAIL_ALBUMS=""
  run_import_ok --resume --keep-work --archive test-a.tgz

  art="$(newest_artifacts)/test-a.tgz"
  log=$(latest_log)
  assert_eq "resume completes albums.json with 2 albums" "$(jq 'length' "$art/albums.json")" "2"
  assert_grep "resume skips AlbumOne" "$log" "AlbumOne.*already processed, skipping"
  assert_grep "resume processes AlbumTwo" "$log" "album: \"AlbumTwo\""
  assert_eq "summary OK after resume" "$(jq -r '.status' "$art/summary.json")" "OK"
  assert_eq "validate_albums.count = 2" "$(jq -r '.validate_albums.count' "$progress")" "2"
  assert_eq "done marked once" "$(grep -c '^test-a.tgz$' "$ROOT/state/done")" "1"
}

# ---------------------------------------------------------------------------
# Scenario 4: old-format takeout — Google Photos/ subfolders become albums.
# ---------------------------------------------------------------------------
t4_old_format() {
  echo "== t4: old-format takeout (Google Photos/ subfolders as albums)"
  new_root
  setup_shims
  make_fixture_b "$ROOT/fixtures/b"
  make_tgz "$ROOT/fixtures/b" "$ROOT/takeout/old-format.tgz"
  run_import_ok --keep-work --archive old-format.tgz

  local art log
  art="$(newest_artifacts)/old-format.tgz"
  log=$(latest_log)
  assert_grep "logs old-format album discovery" "$log" "treating Google Photos/ subfolders as albums"
  assert_eq "discovers 2 albums" "$(jq 'length' "$art/albums-takeout.json")" "2"
  assert_eq "album names" "$(jq -r '[.[].name] | sort | join(",")' "$art/albums-takeout.json")" "Family,Trip 2024"
  assert_eq "all 3 media uploaded" "$(jq -r '.expected_media' "$art/summary.json")" "3"
  assert_eq "2 albums processed" "$(jq -r '.albums_processed' "$art/summary.json")" "2"
  assert_eq "summary OK" "$(jq -r '.status' "$art/summary.json")" "OK"
}

# ---------------------------------------------------------------------------
# Scenario 5: --force resets progress and reprocesses everything.
# ---------------------------------------------------------------------------
t5_force_resets() {
  echo "== t5: --force resets progress (full reprocess)"
  new_root
  setup_shims
  make_fixture_a "$ROOT/fixtures/a"
  make_tgz "$ROOT/fixtures/a" "$ROOT/takeout/test-a.tgz"
  run_import_ok --keep-work --archive test-a.tgz

  local before_upload before_timeline
  before_upload=$(mock_count '^photo upload')
  before_timeline=$(mock_count '^photo timeline')

  run_import_ok --force --keep-work --archive test-a.tgz
  local log
  log=$(latest_log)

  assert_eq "upload re-run twice on --force" "$(( $(mock_count '^photo upload') - before_upload ))" "2"
  assert_eq "timeline re-fetched on --force" "$(( $(mock_count '^photo timeline') - before_timeline ))" "1"
  assert_grep "manifest rebuilt on --force" "$log" "building manifest \(sha1sum of all media files\)"
  assert_grep "junk stripped again on --force" "$log" "stripping macOS metadata junk"
  assert_not_grep "no resume skip messages on --force" "$log" "already done"
}

# ---------------------------------------------------------------------------

t1_full_import
t2_resume_skips_steps
t3_mid_album_failure
t4_old_format
t5_force_resets

echo
echo "== results: $((TESTS_RUN - TESTS_FAIL))/$TESTS_RUN passed"
if (( TESTS_FAIL > 0 )); then
  echo "FAILURES: $TESTS_FAIL"
  exit 1
fi
exit 0
