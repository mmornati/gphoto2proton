# Story 1.5: SQLite State Tracker + Resume Safety

Status: ready-for-dev

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

- [ ] Implement internal/state/sqlite.go — StateTracker adapter
  - [ ] database/sql +