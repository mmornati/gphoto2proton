# Deferred Work

## Deferred from: code review of 2-2-album-recreation-proton.md (2026-07-28)

- `AttachAlbumAdapter` is dead code — `internal/proton/upload.go:89`. No production or test caller in the repository. Useful escape hatch but unused. Reason: pre-existing pattern from earlier adapter work; not introduced or worsened by this story.
- `TestAlbumAdapterAttachToUploader` is a skip-only stub — `internal/proton/album_test.go:410`. No assertion. Reason: pre-existing test cleanup; not part of Story 2.2 scope.