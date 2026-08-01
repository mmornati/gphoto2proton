package proton

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
)

// protonDriveAuthSession mirrors the subset of the session stored by the
// proton-drive CLI (JS SDK format) that gphoto2proton needs. It can be
// dumped with:
//
//	pass show ch.proton.drive/drive-sdk-cli/auth-session
type protonDriveAuthSession struct {
	UserKeyPassword string `json:"userKeyPassword"`
	Session         struct {
		UID          string `json:"uid"`
		AccessToken  string `json:"accessToken"`
		RefreshToken string `json:"refreshToken"`
	} `json:"session"`
}

// LoadProtonDriveSession parses a session file produced by the proton-drive
// CLI and converts it into gphoto2proton's credential format so the sync and
// albums-finalize commands can reuse the login without a password or CAPTCHA.
//
// The JS SDK stores userKeyPassword as the raw salted key-pass bytes; the
// bridge's CredentialData expects the base64 encoding of those bytes.
func LoadProtonDriveSession(r io.Reader) (CredentialData, error) {
	var s protonDriveAuthSession
	if err := json.NewDecoder(r).Decode(&s); err != nil {
		return CredentialData{}, fmt.Errorf("parsing proton-drive session: %w", err)
	}
	if s.Session.UID == "" || s.Session.AccessToken == "" || s.Session.RefreshToken == "" || s.UserKeyPassword == "" {
		return CredentialData{}, fmt.Errorf("proton-drive session is missing required fields")
	}
	return CredentialData{
		UID:           s.Session.UID,
		AccessToken:   s.Session.AccessToken,
		RefreshToken:  s.Session.RefreshToken,
		SaltedKeyPass: base64.StdEncoding.EncodeToString([]byte(s.UserKeyPassword)),
	}, nil
}
