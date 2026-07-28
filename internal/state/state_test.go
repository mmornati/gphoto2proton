package state

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/mmornati/gphoto2proton/internal/domain"
)

func TestNewSQLiteTracker_CreatesTable(t *testing.T) {
	tracker, dbPath := newTracker(t, "session-1")
	defer tracker.Close()

	var tableName string
	err := tracker.db.QueryRow("SELECT name FROM sqlite_master WHERE type='table' AND name='file_states'").Scan(&tableName)
	if err != nil {
		t.Fatalf("file_states table not found: %v", err)
	}
	if _, err := os.Stat(dbPath); err != nil {
		t.Fatalf("db file not created: %v", err)
	}
}

func TestRecord_InsertAndUpdate(t *testing.T) {
	tracker, _ := newTracker(t, "session-1")
	defer tracker.Close()

	if err := tracker.Record(context.Background(), "file-1", domain.StatePending); err != nil {
		t.Fatalf("Record failed: %v", err)
	}
	if err := tracker.Record(context.Background(), "file-1", domain.StateUploaded); err != nil {
		t.Fatalf("Update Record failed: %v", err)
	}
}

func TestRecordFull(t *testing.T) {
	tracker, _ := newTracker(t, "session-1")
	defer tracker.Close()

	err := tracker.RecordFull(context.Background(), "file-1", domain.StateFailed, "photo.jpg", 1024, "timeout")
	if err != nil {
		t.Fatalf("RecordFull failed: %v", err)
	}
}

func TestFileStates_BySession(t *testing.T) {
	tracker1, _ := newTracker(t, "session-1")
	tracker2, _ := newTracker(t, "session-2")

	_ = tracker1.Init(context.Background(), "session-1")
	_ = tracker2.Init(context.Background(), "session-2")

	_ = tracker1.RecordFull(context.Background(), "f1", domain.StateUploaded, "a.jpg", 100, "")
	_ = tracker1.RecordFull(context.Background(), "f2", domain.StateFailed, "b.jpg", 200, "err")
	_ = tracker2.Record(context.Background(), "f3", domain.StatePending)

	entries, err := tracker1.FileStates(context.Background(), "session-1")
	if err != nil {
		t.Fatalf("FileStates failed: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}

	tracker1.Close()
	tracker2.Close()
}

func TestPendingFiles_FiltersCorrectly(t *testing.T) {
	tracker, _ := newTracker(t, "session-1")
	defer tracker.Close()

	_ = tracker.Record(context.Background(), "f1", domain.StateUploaded)
	_ = tracker.Record(context.Background(), "f2", domain.StatePending)
	_ = tracker.Record(context.Background(), "f3", domain.StateFailed)
	_ = tracker.Record(context.Background(), "f4", domain.StateSkipped)

	pending, err := tracker.PendingFiles(context.Background(), "session-1")
	if err != nil {
		t.Fatalf("PendingFiles failed: %v", err)
	}
	if len(pending) != 2 {
		t.Fatalf("expected 2 pending files (pending+failed), got %d", len(pending))
	}
}

func TestDoneFiles_FiltersCorrectly(t *testing.T) {
	tracker, _ := newTracker(t, "session-1")
	defer tracker.Close()

	tracker.Record(context.Background(), "f1", domain.StateUploaded)
	tracker.Record(context.Background(), "f2", domain.StatePending)
	tracker.Record(context.Background(), "f3", domain.StateSkipped)
	tracker.Record(context.Background(), "f4", domain.StateFailed)

	done, err := tracker.DoneFiles(context.Background(), "session-1")
	if err != nil {
		t.Fatalf("DoneFiles failed: %v", err)
	}
	if len(done) != 2 {
		t.Fatalf("expected 2 done files (uploaded+skipped), got %d", len(done))
	}
}

func TestResetFailed(t *testing.T) {
	tracker, _ := newTracker(t, "session-1")
	defer tracker.Close()

	tracker.Record(context.Background(), "f1", domain.StateFailed)
	tracker.Record(context.Background(), "f2", domain.StateUploaded)

	if err := tracker.ResetFailed(context.Background(), "session-1"); err != nil {
		t.Fatalf("ResetFailed failed: %v", err)
	}

	entries, _ := tracker.FileStates(context.Background(), "session-1")
	for _, e := range entries {
		if e.FileID == "f1" && e.State != domain.StatePending {
			t.Fatalf("expected f1 to be reset to pending, got %v", e.State)
		}
		if e.FileID == "f2" && e.State != domain.StateUploaded {
			t.Fatalf("expected f2 to stay uploaded, got %v", e.State)
		}
	}
}

func TestMigrator_UpAndDown(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "migrate.db")
	m := NewMigrator(dbPath)

	if err := m.Up(); err != nil {
		t.Fatalf("Migrator Up failed: %v", err)
	}

	if err := m.Down(); err != nil {
		t.Fatalf("Migrator Down failed: %v", err)
	}
}

func newTracker(t *testing.T, sessionID string) (*SQLiteTracker, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "test.db")
	tracker, err := NewSQLiteTracker(dbPath)
	if err != nil {
		t.Fatalf("NewSQLiteTracker failed: %v", err)
	}
	_ = tracker.Init(context.Background(), sessionID)
	return tracker, dbPath
}
