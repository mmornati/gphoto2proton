package proton

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mmornati/gphoto2proton/internal/port"
)

func TestCompilesProtonUploader(t *testing.T) {
	t.Skip("Uploader construction requires live Proton credential; covered by AlbumAdapter tests")
	var _ port.ProtonUploader = (*Uploader)(nil)
}

func TestCredentialStoreSaveAndLoad(t *testing.T) {
	dir := t.TempDir()
	store := NewCredentialStore(dir)

	cred := CredentialData{
		UID:           "test-uid",
		AccessToken:   "test-access",
		RefreshToken:  "test-refresh",
		SaltedKeyPass: "test-key",
	}

	if err := store.Save(cred); err != nil {
		t.Fatalf("Save failed: %v", err)
	}

	loaded, err := store.Load()
	if err != nil {
		t.Fatalf("Load failed: %v", err)
	}

	if loaded.UID != "test-uid" {
		t.Fatalf("expected test-uid, got: %s", loaded.UID)
	}
	if loaded.AccessToken != "test-access" {
		t.Fatalf("expected test-access, got: %s", loaded.AccessToken)
	}
	if loaded.RefreshToken != "test-refresh" {
		t.Fatalf("expected test-refresh, got: %s", loaded.RefreshToken)
	}
	if loaded.SaltedKeyPass != "test-key" {
		t.Fatalf("expected test-key, got: %s", loaded.SaltedKeyPass)
	}
}

func TestCredentialStoreLoadMissing(t *testing.T) {
	dir := t.TempDir()
	store := NewCredentialStore(dir)

	_, err := store.Load()
	if err != ErrNoSession {
		t.Fatalf("expected ErrNoSession, got: %v", err)
	}
}

func TestCredentialStoreClear(t *testing.T) {
	dir := t.TempDir()
	store := NewCredentialStore(dir)

	_ = store.Save(CredentialData{UID: "test"})

	if err := store.Clear(); err != nil {
		t.Fatalf("Clear failed: %v", err)
	}

	_, err := store.Load()
	if err != ErrNoSession {
		t.Fatalf("expected ErrNoSession after clear, got: %v", err)
	}
}

func TestCredentialStoreClearNoFile(t *testing.T) {
	dir := t.TempDir()
	store := NewCredentialStore(dir)

	if err := store.Clear(); err != nil {
		t.Fatalf("Clear on non-existent should succeed, got: %v", err)
	}
}

func TestCredentialStoreCreatesDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nested", "dir")
	store := NewCredentialStore(dir)

	if err := store.Save(CredentialData{UID: "test"}); err != nil {
		t.Fatalf("Save with nested dirs failed: %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "session.json")); os.IsNotExist(err) {
		t.Fatal("session.json was not created")
	}
}

func TestMimeTypeKnown(t *testing.T) {
	tests := []struct {
		name     string
		expected string
	}{
		{"photo.jpg", "image/jpeg"},
		{"photo.jpeg", "image/jpeg"},
		{"photo.png", "image/png"},
		{"photo.heic", "image/heic"},
		{"video.mov", "video/quicktime"},
		{"video.mp4", "video/mp4"},
		{"raw.cr2", "image/x-canon-cr2"},
		{"raw.nef", "image/x-nikon-nef"},
		{"raw.arw", "image/x-sony-arw"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := mimeType(tt.name)
			if result != tt.expected {
				t.Fatalf("expected %s, got: %s", tt.expected, result)
			}
		})
	}
}

func TestMimeTypeUnknown(t *testing.T) {
	result := mimeType("file.bin")
	if result != "application/octet-stream" {
		t.Fatalf("expected application/octet-stream, got: %s", result)
	}
}

func TestAlbumManagerNotImplemented(t *testing.T) {
	t.Skip("AlbumManager removed; replaced by AlbumAdapter (see album_test.go)")
}
