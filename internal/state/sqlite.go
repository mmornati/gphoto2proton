package state

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

type SQLiteTracker struct {
	db        *sql.DB
	sessionID string
}

func NewSQLiteTracker(dbPath string) (*SQLiteTracker, error) {
	if err := os.MkdirAll(filepath.Dir(dbPath), 0700); err != nil {
		return nil, fmt.Errorf("creating state directory: %w", err)
	}
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, fmt.Errorf("opening sqlite: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("pinging sqlite: %w", err)
	}
	m := NewMigrator(dbPath)
	if err := m.Up(); err != nil {
		db.Close()
		return nil, fmt.Errorf("running migrations: %w", err)
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

func (s *SQLiteTracker) RecordAlbum(ctx context.Context, albumID string, state domain.State) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO album_states (album_id, session_id, state, updated_at)
		 VALUES (?, ?, ?, datetime('now'))
		 ON CONFLICT(album_id, session_id) DO UPDATE SET
		   state = excluded.state,
		   updated_at = datetime('now')`,
		albumID, s.sessionID, state)
	return err
}

func (s *SQLiteTracker) RecordAlbumMembership(ctx context.Context, albumName, fileName string) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO album_members (album_name, file_name, session_id, updated_at)
		 VALUES (?, ?, ?, datetime('now'))
		 ON CONFLICT(album_name, file_name, session_id) DO UPDATE SET
		   updated_at = datetime('now')`,
		albumName, fileName, s.sessionID)
	return err
}

func (s *SQLiteTracker) AccumulatedAlbums(ctx context.Context) ([]domain.Album, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT album_name, file_name FROM album_members
		 ORDER BY album_name, file_name`)
	if err != nil {
		return nil, fmt.Errorf("querying accumulated albums: %w", err)
	}
	defer rows.Close()

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	var entries []struct {
		albumName string
		fileName  string
	}
	for rows.Next() {
		var e struct {
			albumName string
			fileName  string
		}
		if err := rows.Scan(&e.albumName, &e.fileName); err != nil {
			return nil, fmt.Errorf("scanning album member: %w", err)
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	groups := make(map[string][]string)
	order := make([]string, 0)
	for _, e := range entries {
		if _, ok := groups[e.albumName]; !ok {
			order = append(order, e.albumName)
		}
		groups[e.albumName] = append(groups[e.albumName], e.fileName)
	}

	out := make([]domain.Album, 0, len(groups))
	for _, name := range order {
		out = append(out, domain.Album{
			Name:    name,
			FileIDs: groups[name],
		})
	}
	return out, nil
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
	var rows *sql.Rows
	var err error
	if sessionID == "" {
		rows, err = s.db.QueryContext(ctx,
			`SELECT file_id, session_id, state, file_name, file_size, error_msg
			 FROM file_states`)
	} else {
		rows, err = s.db.QueryContext(ctx,
			`SELECT file_id, session_id, state, file_name, file_size, error_msg
			 FROM file_states WHERE session_id = ?`, sessionID)
	}
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
