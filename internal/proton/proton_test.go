package proton

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/mmornati/gphoto2proton/internal/port"
)

func TestProtonAppVersionFormat(t *testing.T) {
	// Proton only accepts third-party app versions matching the documented
	// external-drive-<project>@<semver> format where project conforms to
	// (-[a-z_]+)+; otherwise the auth/info request fails with API error 2064.
	pattern := regexp.MustCompile(`^external-drive(-[a-z_]+)+@[0-9]+\.[0-9]+\.[0-9]+$`)
	if !pattern.MatchString(protonAppVersion) {
		t.Fatalf("protonAppVersion %q does not match external-drive-<project>@<semver> format", protonAppVersion)
	}
}

func TestProtonUserAgentFormat(t *testing.T) {
	// Proton requires the User-Agent to be <platform>-<product> separated
	// by a dash, otherwise the auth/info request fails with API error 2064.
	ua := protonUserAgent()
	if !strings.Contains(ua, "-") {
		t.Fatalf("user agent %q is missing the required platform-product dash", ua)
	}
	if !strings.HasSuffix(ua, "-gphoto2proton") {
		t.Fatalf("user agent %q must end with -gphoto2proton", ua)
	}
	if !strings.HasPrefix(ua, "linux-gphoto2proton") && !strings.HasPrefix(ua, "macos-gphoto2proton") && !strings.HasPrefix(ua, "windows-gphoto2proton") {
		t.Fatalf("user agent %q has unexpected platform token", ua)
	}
}

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
