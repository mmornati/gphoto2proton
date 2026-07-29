# Story 3.3: Schema Dedup & Edge Case Hardening

**Target file**: `_bmad-output/implementation-artifacts/3-3-schema-hardening.md`
**Epic**: 3 (Archive-Aware Streaming & Cross-Archive Albums)

## Acceptance Criteria

1. **No schema duplication**: `album_members` table defined only in `Migrator.Up()` (`migrations.go`). Inline DDL in `NewSQLiteTracker()` removed. Migrator called during tracker init.

2. **Context cancellation**: `AccumulatedAlbums()` checks `ctx.Err()` before iterating query results.

3. **closeFiles nil-guard**: `Reader.closeFiles()` guards against nil `r.files` to prevent double-close panic.

4. **expandMultiPart scoped**: Does not auto-expand when a single archive path is passed via `--takeout-archive`.

5. **All tests pass**: `go test ./...` + `go vet` + `golangci-lint`.

## Files to Touch

| File | Change |
|---|---|
| `internal/state/sqlite.go` | Remove inline DDL; call `Migrator.Up()`; add `ctx.Err()` check |
| `internal/state/state_test.go` | Add context cancellation test |
| `internal/takeout/stream.go` | Add nil-guard; scope `expandMultiPart` |
| `internal/takeout/takeout_test.go` | Add double-close and single-archive tests |
