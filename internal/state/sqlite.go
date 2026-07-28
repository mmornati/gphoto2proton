package state

import (
	"context"
	"database/sql"
	"fmt"

	_ "modernc.org/sqlite"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

type SQLiteTracker struct {
	db        *sql.DB
	sessionID string
}

func NewSQLiteTracker(dbPath string) (*SQLiteTracker, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("opening sqlite: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("pinging sqlite: %w", err)
	}
	if _, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS file_states (
			file_id    TEXT PRIMARY KEY,
			session_id TEXT NOT NULL,
			state      INTEGER NOT NULL,
			file_name  TEXT NOT NULL DEFAULT '',
			file_size  INTEGER NOT NULL DEFAULT 0,
			error_msg  TEXT NOT NULL DEFAULT '',
			updated_at TEXT NOT NULL DEFAULT (datetime('now'))
		)
	`); err != nil {
		db.Close()
		return nil, fmt.Errorf("creating table: %w", err)
	}
	return &SQLiteTracker{db: db}, nil
}

func (s *SQLiteTracker) Init(ctx context.Context, sessionID string) error {
	s.sessionID = sessionID
	return nil
}

func (s *SQLiteTracker) Record(ctx context.Context, fileID string, state domain.State) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO file_states (file_id, session_id, state, updated_at)
		 VALUES (?, ?, ?, datetime('now'))
		 ON CONFLICT(file_id) DO UPDATE SET
		   state = excluded.state,
		   updated_at = datetime('now')`,
		fileID, s.sessionID, state)
	return err
}

func (s *SQLiteTracker) RecordFull(ctx context.Context, fileID string, state domain.State, fileName string, fileSize int64, errorMsg string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO file_states (file_id, session_id, state, file_name, file_size, error_msg, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, datetime('now'))
		 ON CONFLICT(file_id) DO UPDATE SET
		   state = excluded.state,
		   file_name = excluded.file_name,
		   file_size = excluded.file_size,
		   error_msg = excluded.error_msg,
		   updated_at = datetime('now')`,
		fileID, s.sessionID, state, fileName, fileSize, errorMsg)
	return err
}

func (s *SQLiteTracker) FileStates(ctx context.Context, sessionID string) ([]port.FileEntry, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT file_id, session_id, state, file_name, file_size, error_msg
		 FROM file_states WHERE session_id = ?`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("querying file states: %w", err)
	}
	defer rows.Close()

	var entries []port.FileEntry
	for rows.Next() {
		var e port.FileEntry
		var stateInt int
		if err := rows.Scan(&e.FileID, &e.SessionID, &stateInt, &e.FileName, &e.FileSize, &e.ErrorMsg); err != nil {
			return nil, fmt.Errorf("scanning row: %w", err)
		}
		e.State = domain.State(stateInt)
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

func (s *SQLiteTracker) PendingFiles(ctx context.Context, sessionID string) ([]port.FileEntry, error) {
	all, err := s.FileStates(ctx, sessionID)
	if err != nil {
		return nil, err
	}
	var pending []port.FileEntry
	for _, e := range all {
		if e.State == domain.StatePending || e.State == domain.StateFailed {
			pending = append(pending, e)
		}
	}
	return pending, nil
}

func (s *SQLiteTracker) DoneFiles(ctx context.Context, sessionID string) ([]port.FileEntry, error) {
	all, err := s.FileStates(ctx, sessionID)
	if err != nil {
		return nil, err
	}
	var done []port.FileEntry
	for _, e := range all {
		if e.State == domain.StateUploaded || e.State == domain.StateSkipped {
			done = append(done, e)
		}
	}
	return done, nil
}

func (s *SQLiteTracker) ResetFailed(ctx context.Context, sessionID string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE file_states SET state = ?, updated_at = datetime('now')
		 WHERE session_id = ? AND state = ?`,
		domain.StatePending, sessionID, domain.StateFailed)
	return err
}

func (s *SQLiteTracker) Close() error {
	return s.db.Close()
}
