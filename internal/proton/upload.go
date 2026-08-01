package proton

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/mmornati/gphoto2proton/internal/port"
	"github.com/rclone/Proton-API-Bridge"
	"github.com/rclone/Proton-API-Bridge/common"
	proton "github.com/rclone/go-proton-api"
)

const (
	// protonAppVersion is the x-pm-appversion header value sent to Proton.
	// Rules verified live against POST /auth/v4/info (2026-07-31):
	//
	//   - must be external-drive-<name>@<semver>[-<channel>]; anything else
	//     fails with HTTP 400 / API error 2064 ("platform and product must
	//     be separated by a dash").
	//   - <name> is a SINGLE section: inner dashes are rejected with 2064
	//     "Invalid section name" (external-drive-gphoto-proton@... fails).
	//     Underscores are fine (external-drive-gphoto_proton@... passes).
	//   - the live server accepts digits in <name> and a bare <semver>, but
	//     the stricter regex published by a Proton Drive engineer in
	//     rclone/rclone#9189 does not; we stay in the intersection of both
	//     (letters+underscores name, explicit -stable channel) to be robust
	//     against future server-side tightening.
	//
	// Why the rclone identifier: Proton's block-upload endpoint
	// (POST /drive/blocks) rejects every third-party app-version it does
	// not recognise with HTTP 400 / Code=2000 ("You are using an outdated
	// version of the app"). Proton keeps a server-side compatibility
	// exception keyed on the "external-drive-rclone" name until their
	// Drive SDK is stable and available to third parties (see the Proton
	// Drive engineer's comment in rclone/rclone#9189). Any other
	// identifier — including our previous external-drive-gphoto_proton —
	// passes auth but is refused on upload. Verified live 2026-08-01:
	// identical requests succeed with this value and fail with our own.
	// Once Proton allowlists third-party clients (or ships a public SDK),
	// this should be reverted to an external-drive-gphoto_proton version.
	protonAppVersion = "external-drive-rclone@1.73.0-stable"
)

// protonUserAgent returns the User-Agent header value for Proton requests.
// Proton does not appear to validate the User-Agent format server-side
// (rclone sends "rclone/vX.Y.Z" without any dash and works), but we send a
// <platform>-<product> shaped value to look like a first-party client.
func protonUserAgent() string {
	return fmt.Sprintf("%s-gphoto2proton", protonPlatform())
}

// protonPlatform maps the runtime GOOS to the platform token Proton accepts
// (linux, windows, macos, android, ios, web).
func protonPlatform() string {
	switch runtime.GOOS {
	case "darwin":
		return "macos"
	case "windows":
		return "windows"
	default:
		return "linux"
	}
}

var mimeTypes = map[string]string{
	".jpg":  "image/jpeg",
	".jpeg": "image/jpeg",
	".png":  "image/png",
	".heic": "image/heic",
	".mov":  "video/quicktime",
	".mp4":  "video/mp4",
	".cr2":  "image/x-canon-cr2",
	".nef":  "image/x-nikon-nef",
	".arw":  "image/x-sony-arw",
}

type Uploader struct {
	drive       *proton_api_bridge.ProtonDrive
	credStore   *CredentialStore
	username    string
	password    string
	albumClient *AlbumAdapter
}

func NewUploader(ctx context.Context, username, password, twoFA string, credStore *CredentialStore) (port.ProtonUploader, error) {
	config := common.NewConfigWithDefaultValues()
	config.AppVersion = protonAppVersion
	config.UserAgent = protonUserAgent()

	// Replace drafts left behind by failed/interrupted uploads instead of
	// failing with ErrDraftExists, so a retried sync can always make
	// progress (the bridge's default is the conservative false).
	config.ReplaceExistingDraft = true

	cred, err := credStore.Load()
	if err == nil {
		config.UseReusableLogin = true
		config.ReusableCredential = &common.ReusableCredentialData{
			UID:           cred.UID,
			AccessToken:   cred.AccessToken,
			RefreshToken:  cred.RefreshToken,
			SaltedKeyPass: cred.SaltedKeyPass,
		}
	} else {
		config.FirstLoginCredential = &common.FirstLoginCredentialData{
			Username: username,
			Password: password,
			TwoFA:    twoFA,
		}
	}

	drive, driveCred, err := proton_api_bridge.NewProtonDrive(
		ctx,
		config,
		func(auth proton.Auth) {},
		func() {},
	)
	if err != nil {
		return nil, fmt.Errorf("creating proton drive: %w", err)
	}

	if driveCred != nil {
		if err := credStore.Save(CredentialData{
			UID:           driveCred.UID,
			AccessToken:   driveCred.AccessToken,
			RefreshToken:  driveCred.RefreshToken,
			SaltedKeyPass: driveCred.SaltedKeyPass,
		}); err != nil {
			return nil, fmt.Errorf("saving credentials: %w", err)
		}
	}

	return &Uploader{
		drive:       drive,
		credStore:   credStore,
		username:    username,
		password:    password,
		albumClient: NewAlbumAdapter(credStore, username),
	}, nil
}

// AttachAlbumAdapter wires an externally constructed AlbumAdapter to the
// Uploader. Used when the caller needs to override defaults (e.g. test
// HTTP transport, custom retry settings) without going through NewUploader.
func (u *Uploader) AttachAlbumAdapter(adapter *AlbumAdapter) {
	u.albumClient = adapter
}

func (u *Uploader) Upload(ctx context.Context, name string, r io.Reader) (string, error) {
	folderID, err := u.ensureFolder(ctx, "gphoto2proton")
	if err != nil {
		return "", fmt.Errorf("ensuring folder: %w", err)
	}

	fileID, _, err := u.drive.UploadFileByReader(
		ctx,
		folderID,
		name,
		time.Now(),
		r,
		0,
	)
	if err != nil {
		return "", fmt.Errorf("uploading file: %w", err)
	}

	return fileID, nil
}

func (u *Uploader) CreateAlbum(ctx context.Context, name string, fileIDs []string) (string, error) {
	if u.albumClient == nil {
		return "", fmt.Errorf("album: adapter not configured")
	}
	return u.albumClient.CreateAlbum(ctx, name, fileIDs)
}

func (u *Uploader) ensureFolder(ctx context.Context, folderName string) (string, error) {
	rootID := u.drive.RootLink.LinkID

	existing, err := u.drive.SearchByNameInActiveFolderByID(ctx, rootID, folderName, false, true, proton.LinkStateActive)
	if err == nil && existing != nil {
		return existing.LinkID, nil
	}

	folderID, err := u.drive.CreateNewFolderByID(ctx, rootID, folderName)
	if err != nil {
		return "", fmt.Errorf("creating folder %s: %w", folderName, err)
	}

	return folderID, nil
}

func mimeType(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if mime, ok := mimeTypes[ext]; ok {
		return mime
	}
	return "application/octet-stream"
}
