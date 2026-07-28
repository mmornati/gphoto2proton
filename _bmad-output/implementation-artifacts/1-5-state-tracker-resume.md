# Story 1.5: SQLite State Tracker + Resume Safety

Status: review
baseline_commit: 88d5b6a

## Story

As a user migrating a large photo library,
I want gphoto2proton to track each file's state and support --resume,
so that an interrupted migration picks up where it left off without duplicates or gaps.

## Acceptance Criteria

1. Given a migration in progress, When interrupted and restarted with --resume, Then completed files (done) are skipped
2. Given a migration in progress, When interrupted during upload, Then files in processing/uploaded state are retried
3. Given a migration session ID, When Record() is called for a file, Then the state is persisted to SQLite
4. Given an existing session, When --resume is called, Then the state file is loaded and in-flight files are correctly classified
5. Given the SQLite database, When queried, Then it contains exactly the columns: file_id, session_id, state, file_name, file_size, error_msg, updated_at
6. Given a file that previously failed, When --resume is called, Then the file is retried (failed → pending)

## Tasks / Subtasks

- [x] Implement internal/state/sqlite.go — StateTracker adapter
  - [x] database/sql + modernc.org/sqlite driver (pure Go, no CGO)
  - [x] CREATE TABLE IF NOT EXISTS file_states with all 7 required columns
  - [x] Record() with upsert (ON CONFLICT DO UPDATE)
  - [x] RecordFull() with file_name, file_size, error_msg
  - [x] FileStates() query by session_id
  - [x] PendingFiles() filtering (pending + failed states)
  - [x] DoneFiles() filtering (uploaded + skipped states)
  - [x] ResetFailed() converting failed → pending for retry
  - [x] Close() for db lifecycle
- [x] Implement internal/state/migrations.go — schema management
  - [x] Up() creates file_states table
  - [x] Down() drops file_states table
- [x] Add domain.StateProcessing for in-flight files

## Dev Notes

### SQLite schema

```sql
CREATE TABLE IF NOT EXISTS file_states (
    file_id    TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    state      INTEGER NOT NULL,
    file_name  TEXT NOT NULL DEFAULT '',
    file_size  INTEGER NOT NULL DEFAULT 0,
    error_msg  TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### New state added

- `StateProcessing` — file currently being processed (between pending and uploaded)

### Port interface additions

```go
type FileEntry struct {
    FileID, SessionID, FileName, ErrorMsg string
    State                                 domain.State
    FileSize                              int64
}

type StateTracker interface {
    Init(ctx, sessionID)
    Record(ctx, fileID, state)
    FileStates(ctx, sessionID) ([]FileEntry, error)
    Close() error
}
```

## References

- [Architecture Spine: AD-4 — SQLite state persistence]
- [Product Brief: FR5 — Resume from interruption]
- [SQLite pragma: WAL journal for concurrent safety]

## File List

- internal/domain/migration.go — added StateProcessing
- internal/port/state.go — added FileEntry, FileStates(), Close()
- internal/state/sqlite.go — full SQLiteTracker implementation
- internal/state/migrations.go — schema management
- internal/state/state_test.go — 8 new tests

## Change Log

- Implemented SQLiteTracker with full CRUD and resume support
- Added StateProcessing to domain states
- Added FileEntry type and FileStates/Close to port interface
- Added modernc.org/sqlite dependency (pure Go, no CGO)
