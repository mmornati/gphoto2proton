package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

type sessionData struct {
	UID           string `json:"uid"`
	AccessToken   string `json:"accessToken"`
	RefreshToken  string `json:"refreshToken"`
	SaltedKeyPass string `json:"saltedKeyPass"`
}

var probeEndpoints = []struct {
	name string
	url  string
}{
	{"Photos API root", "https://photos-api.proton.me"},
	{"Photos API v1 albums", "https://photos-api.proton.me/photos/v1/albums"},
	{"Photos API v1", "https://photos-api.proton.me/photos/v1"},
	{"Drive API albums (fallback)", "https://drive-api.proton.me/drive/v1/albums"},
}

func main() {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "home dir: %v\n", err)
		os.Exit(1)
	}

	sessionPath := filepath.Join(home, ".gphoto2proton", "session.json")
	data, err := os.ReadFile(sessionPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "No session found at %s\n", sessionPath)
		fmt.Fprintf(os.Stderr, "Run gphoto2proton sync first to authenticate.\n")
		os.Exit(1)
	}

	var session sessionData
	if err := json.Unmarshal(data, &session); err != nil {
		fmt.Fprintf(os.Stderr, "Invalid session: %v\n", err)
		os.Exit(1)
	}

	client := &http.Client{Timeout: 10 * time.Second}

	fmt.Println("=== Proton Photos API Probe ===")
	fmt.Printf("Session UID: %s\n", session.UID)
	fmt.Printf("Access Token: %s...\n", safePrefix(session.AccessToken, 20))
	fmt.Println()

	for _, ep := range probeEndpoints {
		fmt.Printf("Probing: %s (%s)\n", ep.name, ep.url)
		probeEndpoint(client, &session, ep.url)
		fmt.Println()
	}

	fmt.Println("=== Summary ===")
	fmt.Println("If any endpoint returned 200, the Photos API is reachable.")
	fmt.Println("Check the response body above for album-related endpoints.")
	fmt.Println("Update epics.md and research doc with findings.")
}

func probeEndpoint(client *http.Client, session *sessionData, url string) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		fmt.Printf("  ERROR creating request: %v\n", err)
		return
	}
	req.Header.Set("Authorization", "Bearer "+session.AccessToken)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "gphoto2proton-probe/1.0")
	req.Header.Set("x-pm-uid", session.UID)

	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("  ERROR: %v\n", err)
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	fmt.Printf("  Status: %s\n", resp.Status)
	fmt.Printf("  Headers:\n")
	for k, v := range resp.Header {
		if len(v) > 0 {
			fmt.Printf("    %s: %s\n", k, v[0])
		}
	}
	if len(body) > 0 {
		fmt.Printf("  Body: %s\n", truncate(string(body), 500))
	}
}

func safePrefix(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
