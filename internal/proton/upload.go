package proton

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/henrybear327/Proton-API-Bridge"
	"github.com/henrybear327/Proton-API-Bridge/common"
	proton "github.com/henrybear327/go-proton-api"
	"github.com/mmornati/gphoto2proton/internal/port"
)

const (
	// protonAppVersion is the x-pm-appversion header value sent to Proton.
	// Proton only accepts third-party clients using the
	// external-drive-<project>@<semver-version> format where the project name
	// conforms to (-[a-z_]+)+; any other pattern is rejected with API error
	// 2064 during the first auth/info request.
	protonAppVersion = "external-drive-gphoto-proton@0.1.0"
)

// protonUserAgent returns the User-Agent header value for Proton requests.
// Proton requires the platform-product format with a dash separating the
// application platform from the product name.
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

	existing, err := u.drive.SearchByNameInActiveFolderByID(ctx, rootID, folderName, false, true, 0)
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
