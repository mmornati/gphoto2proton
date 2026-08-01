package proton

// Live integration tests against the real Proton API. They are skipped
// unless explicitly enabled:
//
//	GPHOTO2PROTON_INTEGRATION=1 \
//	PROTON_USERNAME=you@proton.me \
//	PROTON_PASSWORD=... \
//	PROTON_2FA=123456 \
//	go test ./internal/proton/ -run Integration -v
//
// PROTON_2FA is only needed when no reusable session exists. Set
// PROTON_STATE_DIR to a persistent directory to reuse the saved session
// across runs and avoid burning a TOTP code each time.

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/mmornati/gphoto2proton/internal/port"
)

func integrationSetup(t *testing.T) (context.Context, *CredentialStore) {
	t.Helper()
	if os.Getenv("GPHOTO2PROTON_INTEGRATION") != "1" {
		t.Skip("set GPHOTO2PROTON_INTEGRATION=1 to run live Proton integration tests")
	}
	if os.Getenv("PROTON_USERNAME") == "" {
		t.Skip("PROTON_USERNAME not set")
	}

	stateDir := os.Getenv("PROTON_STATE_DIR")
	if stateDir == "" {
		stateDir = t.TempDir()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	return ctx, NewCredentialStore(stateDir)
}

func integrationLogin(t *testing.T) (context.Context, port.ProtonUploader) {
	t.Helper()
	ctx, store := integrationSetup(t)
	up, err := NewUploader(ctx,
		os.Getenv("PROTON_USERNAME"),
		os.Getenv("PROTON_PASSWORD"),
		os.Getenv("PROTON_2FA"),
		store,
	)
	if err != nil {
		t.Fatalf("NewUploader failed (app-version %q): %v", protonAppVersion, err)
	}
	return ctx, up
}

// TestIntegrationAuthHeaders verifies that the x-pm-appversion and
// User-Agent headers sent during login pass Proton's server-side
// validation. Regression test for HTTP 400 / API error 2064 on
// POST /auth/v4/info ("Application platform and product must be
// separated by a dash").
func TestIntegrationAuthHeaders(t *testing.T) {
	ctx, store := integrationSetup(t)
	up, err := NewUploader(ctx,
		os.Getenv("PROTON_USERNAME"),
		os.Getenv("PROTON_PASSWORD"),
		os.Getenv("PROTON_2FA"),
		store,
	)
	if err != nil {
		t.Fatalf("login failed with app-version %q: %v", protonAppVersion, err)
	}
	if up == nil {
		t.Fatal("expected non-nil uploader")
	}
	if _, err := store.Load(); err != nil {
		t.Fatalf("expected credentials to be persisted: %v", err)
	}
	t.Logf("login OK with app-version %q, user-agent %q", protonAppVersion, protonUserAgent())
}

// TestIntegrationImportedSessionReadOnly imports a proton-drive session file
// (JS SDK format, e.g. from `pass show ch.proton.drive/drive-sdk-cli/auth-session`)
// and verifies it authenticates against the live API using strictly read-only
// operations (About + listing the root folder). Nothing is created, modified
// or deleted on the drive.
//
//	PROTON_DRIVE_SESSION=/path/to/auth-session.json
func TestIntegrationImportedSessionReadOnly(t *testing.T) {
	ctx, _ := integrationSetup(t)

	src := os.Getenv("PROTON_DRIVE_SESSION")
	if src == "" {
		t.Skip("PROTON_DRIVE_SESSION (path to proton-drive auth-session JSON) not set")
	}
	f, err := os.Open(src)
	if err != nil {
		t.Fatalf("opening session file: %v", err)
	}
	defer f.Close()

	stateDir := os.Getenv("PROTON_STATE_DIR")
	if stateDir == "" {
		stateDir = t.TempDir()
	}
	store := NewCredentialStore(stateDir)

	cred, err := LoadProtonDriveSession(f)
	if err != nil {
		t.Fatalf("LoadProtonDriveSession: %v", err)
	}
	if err := store.Save(cred); err != nil {
		t.Fatalf("saving imported session: %v", err)
	}

	up, err := NewUploader(ctx, "", "", "", store)
	if err != nil {
		t.Fatalf("NewUploader with imported session failed (app-version %q): %v", protonAppVersion, err)
	}
	u, ok := up.(*Uploader)
	if !ok {
		t.Fatalf("expected *Uploader, got %T", up)
	}

	about, err := u.drive.About(ctx)
	if err != nil {
		t.Fatalf("About (read-only) failed with imported session: %v", err)
	}
	t.Logf("About OK: user=%s usedSpace=%d", about.Name, about.UsedSpace)

	entries, err := u.drive.ListDirectory(ctx, u.drive.RootLink.LinkID)
	if err != nil {
		t.Fatalf("ListDirectory (read-only) failed with imported session: %v", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name)
	}
	t.Logf("root folder has %d entries: %v", len(entries), names)
}

// TestIntegrationAlbumRoundTrip creates and deletes an album via the live
// Proton Photos API, verifying that photos-api.proton.me accepts the
// request headers (Authorization, x-pm-uid, x-pm-appversion, User-Agent).
func TestIntegrationAlbumRoundTrip(t *testing.T) {
	ctx, up := integrationLogin(t)

	const albumName = "gphoto2proton-itest"
	albumID, err := up.CreateAlbum(ctx, albumName, nil)
	if err != nil {
		t.Fatalf("CreateAlbum failed: %v", err)
	}
	t.Logf("created album %q (id=%s)", albumName, albumID)

	u, ok := up.(*Uploader)
	if !ok {
		t.Fatalf("expected *Uploader, got %T", up)
	}
	if err := u.albumClient.deleteAlbum(ctx, albumID); err != nil {
		t.Logf("WARNING: could not delete test album %s, remove it manually: %v", albumID, err)
	} else {
		t.Logf("deleted album %s", albumID)
	}
}
