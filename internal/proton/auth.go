package proton

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

var ErrNoSession = errors.New("no saved session found")

type CredentialStore struct {
	sessionPath string
}

type CredentialData struct {
	UID           string `json:"uid"`
	AccessToken   string `json:"accessToken"`
	RefreshToken  string `json:"refreshToken"`
	SaltedKeyPass string `json:"saltedKeyPass"`
}

func NewCredentialStore(sessionDir string) *CredentialStore {
	return &CredentialStore{
		sessionPath: filepath.Join(sessionDir, "session.json"),
	}
}

func (c *CredentialStore) Save(cred CredentialData) error {
	dir := filepath.Dir(c.sessionPath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("creating session dir: %w", err)
	}
	data, err := json.MarshalIndent(cred, "", "  ")
	if err != nil {
		return fmt.Errorf("marshaling session: %w", err)
	}
	return os.WriteFile(c.sessionPath, data, 0600)
}

func (c *CredentialStore) Load() (CredentialData, error) {
	data, err := os.ReadFile(c.sessionPath)
	if err != nil {
		if os.IsNotExist(err) {
			return CredentialData{}, ErrNoSession
		}
		return CredentialData{}, fmt.Errorf("reading session: %w", err)
	}
	var cred CredentialData
	if err := json.Unmarshal(data, &cred); err != nil {
		return CredentialData{}, fmt.Errorf("unmarshaling session: %w", err)
	}
	return cred, nil
}

func (c *CredentialStore) Clear() error {
	err := os.Remove(c.sessionPath)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}
