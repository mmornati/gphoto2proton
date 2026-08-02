# Deferred Work

## Deferred from: code review of 2-2-album-recreation-proton.md (2026-07-28)

- `AttachAlbumAdapter` is dead code — `internal/proton/upload.go:89`. No production or test caller in the repository. Useful escape hatch but unused. Reason: pre-existing pattern from earlier adapter work; not introduced or worsened by this story.
- `TestAlbumAdapterAttachToUploader` is a skip-only stub — `internal/proton/album_test.go:410`. No assertion. Reason: pre-existing test cleanup; not part of Story 2.2 scope.

## Deferred from: code review (2026-08-02)

- `recovery.tsv` is write-only; archives with `media_missing > 0` are still marked done — `scripts/gphoto2proton-import.sh:427,654`. Reason: soft-fail + recovery-file was the explicitly requested behavior; tooling to reprocess recovery entries is future work (e.g. a `--reprocess-recovery` mode).
- `--albums-only` never cleans `extract_dir` — `scripts/gphoto2proton-import.sh:650`. Extracted trees accumulate across runs (preflight disk check mitigates). Reason: intentional keep-for-recovery per user request; revisit if disk pressure appears.
- Timeline-fetch immediately after upload can flag just-uploaded files as missing (Proton eventual consistency), silently polluting `recovery.tsv` — `scripts/gphoto2proton-import.sh:607-616`. Reason: no unambiguous fix (needs re-fetch/retry strategy); previously fatal, now a soft record — verify recovery entries before acting on them.
- Manifest cache "reusing cached manifest" never fires across runs (same per-invocation `run-$RUN_TS` artifact-dir flaw as `--resume`) — `scripts/gphoto2proton-import.sh:537`. Reason: pre-existing issue, not caused by this change.