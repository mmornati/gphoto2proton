# Story 3.3: Schema Dedup & Edge Case Hardening

Status: ready-for-dev

## Story

As a developer maintaining gphoto2proton,
I want the SQLite schema defined in exactly one place and edge cases in the streaming reader properly handled,
so that schema drift is impossible and the reader doesn't panic or unexpectedly expand single-archive inputs.

## Acceptance Criteria

1. **No schema duplication**: The `album_members` table is defined only in `Migrator.Up()` under `internal/state/migrations.go`. The inline `CREATE TABLE IF NOT EXISTS` in `NewSQLiteTracker()` is removed. The migrator is called during `NewSQLiteTracker` initialization so behavior is unchanged.

2. **Context cancellation in AccumulatedAlbums**: `AccumulatedAlbums()` checks `ctx.Err()` before iterating query results and returns early if the context is cancelled.

3. **closeFiles nil-guard**: `Reader.closeFiles()` guards against a nil `r.files` slice to prevent panic on double-close.

4. **expandMultiPart scoped correctly**: Single-archive calls to `NewStreamReader` (via `--takeout-archive`) do not auto-expand to process additional files in the same directory.

5. **All existing tests pass**: `go test ./...` passes. `go vet ./...` and `golangci-lint run ./...` pass.

## Tasks / Subtasks

- [ ] 1. Remove schema duplication (AC: 1)
  - [ ] 1.1 Remove inline `album_members` CREATE TABLE from `NewSQLiteTracker()` in `sqlite.go`
  - [ ] 1.2 Call `Migrator.Up()` inside `NewSQLiteTracker` after DB open
  - [ ] 1.3 Verify all existing state tests still pass

- [ ] 2. Add context cancellation check (AC: 2)
  - [ ] 2.1 In `AccumulatedAlbums()`, add `ctx.Err()` check before row iteration
  - [ ] 2.2 Add test: `TestAccumulatedAlbumsContextCancellation`

- [ ] 3. Add closeFiles nil-guard (AC: 3)
  - [ ] 3.1 In `Reader.closeFiles()`, add nil-guard before iterating `r.files`
  - [ ] 3.2 Add test: double-call to EOF does not panic

- [ ] 4. Fix expandMultiPart scope (AC: 4)
  - [ ] 4.1 Only expand multi-part archives when multiple paths are passed to `NewStreamReader`
  - [ ] 4.2 Update tests that depend on multi-part behavior

- [ ] 5. Regression verification (AC: 5)
  - [ ] 5.1 Run `go test ./...`
  - [ ] 5.2 Run `go vet ./...`
  - [ ] 5.3 Run `golangci-lint run ./...`

## Dev Notes

### Architecture constraints (from ARCHITECTURE-SPINE.md)

- **AD-4 (State Storage)**: *"Schema is managed via Go migration functions, never raw SQL files."* Inline DDL violates this.
- **AD-9 (State Machine)**: `album_members` consistency is critical for cross-session album accumulation.

### Key design decisions

- Migrator called inside `NewSQLiteTracker` ensures idempotent schema creation while keeping the definition in `migrations.go`.
- `expandMultiPart` preserved for multi-path calls (e.g., `NewStreamReader("part1.tar", "part2.tar")`) but not activated for single-path calls.

### Files to touch

| File | Change |
|---|---|
| `internal/state/sqlite.go` | Remove inline DDL; call `Migrator.Up()`; add `ctx.Err()` check |
| `internal/state/state_test.go` | Add context cancellation test |
| `internal/takeout/stream.go` | Add nil-guard; scope `expandMultiPart` |
| `internal/takeout/takeout_test.go` | Add double-close and single-archive tests |

### References

- [Source: ARCHITECTURE-SPINE.md] AD-4, AD-9
- [Source: internal/state/sqlite.go:28-55] Inline DDL
- [Source: internal/state/migrations.go:24-49] Migrator.Up()
- [Source: internal/state/sqlite.go:96-140] AccumulatedAlbums
- [Source: internal/takeout/stream.go:57-76] expandMultiPart
- [Source: internal/takeout/stream.go:186-191] closeFiles
