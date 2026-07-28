package state

import (
	"database/sql"

	_ "modernc.org/sqlite" // sqlite driver
)

type Migrator struct {
	dbPath string
}

func NewMigrator(dbPath string) *Migrator {
	return &Migrator{dbPath: dbPath}
}

func (m *Migrator) Up() error {
	db, err := sql.Open("sqlite", m.dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS file_states (
			file_id    TEXT PRIMARY KEY,
			session_id TEXT NOT NULL,
			state      INTEGER NOT NULL,
			file_name  TEXT NOT NULL DEFAULT '',
			file_size  INTEGER NOT NULL DEFAULT 0,
			error_msg  TEXT NOT NULL DEFAULT '',
			updated_at TEXT NOT NULL DEFAULT (datetime('now'))
		);
		CREATE TABLE IF NOT EXISTS album_states (
			album_id   TEXT NOT NULL,
			session_id TEXT NOT NULL,
			state      INTEGER NOT NULL,
			updated_at TEXT NOT NULL DEFAULT (datetime('now')),
			PRIMARY KEY (album_id, session_id)
		);
		CREATE TABLE IF NOT EXISTS album_members (
			album_name TEXT NOT NULL,
			file_name  TEXT NOT NULL,
			session_id TEXT NOT NULL DEFAULT '',
			updated_at TEXT NOT NULL DEFAULT (datetime('now')),
			PRIMARY KEY (album_name, file_name, session_id)
		)
	`)
	return err
}

func (m *Migrator) Down() error {
	db, err := sql.Open("sqlite", m.dbPath)
	if err != nil {
		return err
	}
	defer db.Close()

	_, err = db.Exec(`
		DROP TABLE IF EXISTS album_members;
		DROP TABLE IF EXISTS album_states;
		DROP TABLE IF EXISTS file_states
	`)
	return err
}
