package proton

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestLoadProtonDriveSession_Valid(t *testing.T) {
	const input = `{
  "cachePassword": "abc=",
  "userKeyPassword": "nqJVDqWVuY1mLhJgoagq7cYH9L.z6iW",
  "session": {
    "accessToken": "access123",
    "refreshToken": "refresh123",
    "uid": "uid123"
  },
  "telemetryEnabled": true
}`
	cred, err := LoadProtonDriveSession(strings.NewReader(input))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cred.UID != "uid123" {
		t.Errorf("UID: got %q, want uid123", cred.UID)
	}
	if cred.AccessToken != "access123" {
		t.Errorf("AccessToken: got %q, want access123", cred.AccessToken)
	}
	if cred.RefreshToken != "refresh123" {
		t.Errorf("RefreshToken: got %q, want refresh123", cred.RefreshToken)
	}
	if cred.SaltedKeyPass != base64.StdEncoding.EncodeToString([]byte("nqJVDqWVuY1mLhJgoagq7cYH9L.z6iW")) {
		t.Errorf("SaltedKeyPass: got %q, want base64 of the userKeyPassword value", cred.SaltedKeyPass)
	}
}

func TestLoadProtonDriveSession_InvalidJSON(t *testing.T) {
	if _, err := LoadProtonDriveSession(strings.NewReader("not-json")); err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestLoadProtonDriveSession_MissingFields(t *testing.T) {
	cases := []string{
		`{}`,
		`{"session":{"accessToken":"a","refreshToken":"r"}}`,
		`{"userKeyPassword":"k","session":{"accessToken":"a","refreshToken":"r"}}`,
	}
	for _, in := range cases {
		if _, err := LoadProtonDriveSession(strings.NewReader(in)); err == nil {
			t.Fatalf("expected error for session %q", in)
		}
	}
}
