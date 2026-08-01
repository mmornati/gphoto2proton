// Copyright (c) 2026 mmornati
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
package proton

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func newTestAlbumAdapter(t *testing.T, serverURL string, opts ...AlbumAdapterOption) *AlbumAdapter {
	t.Helper()
	dir := t.TempDir()
	store := NewCredentialStore(dir)
	if err := store.Save(CredentialData{
		UID:           "uid-123",
		AccessToken:   "token-abc",
		RefreshToken:  "refresh-xyz",
		SaltedKeyPass: "key-pass",
	}); err != nil {
		t.Fatalf("seeding credential store: %v", err)
	}
	allOpts := []AlbumAdapterOption{
		WithAlbumAPIBase(serverURL),
		WithAlbumHTTPClient(&http.Client{Timeout: 5 * time.Second}),
		WithAlbumRetryConfig(3, 1*time.Millisecond, 5*time.Millisecond),
		WithAlbumClock(time.Now, func(_ context.Context, _ time.Duration) error { return nil }),
	}
	allOpts = append(allOpts, opts...)
	return NewAlbumAdapter(store, "test@example.com", allOpts...)
}

func TestAlbumAdapterCreateAlbumHappyPath(t *testing.T) {
	var createCalls, photosCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/photos/v1/albums":
			createCalls++
			if r.Method != http.MethodPost {
				t.Errorf("expected POST, got %s", r.Method)
			}
			if auth := r.Header.Get("Authorization"); auth != "Bearer token-abc" {
				t.Errorf("unexpected auth header: %q", auth)
			}
			if uid := r.Header.Get("x-pm-uid"); uid != "uid-123" {
				t.Errorf("unexpected x-pm-uid: %q", uid)
			}
			if av := r.Header.Get("x-pm-appversion"); av != protonAppVersion {
				t.Errorf("unexpected x-pm-appversion: %q", av)
			}
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decoding body: %v", err)
			}
			if body["Name"] != "Vacation 2024" {
				t.Errorf("unexpected album name: %q", body["Name"])
			}
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-abc", Name: "Vacation 2024"},
			}); err != nil {
				t.Fatalf("encoding response: %v", err)
			}
		case "/photos/v1/albums/album-abc/photos":
			photosCalls++
			var body map[string][]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decoding body: %v", err)
			}
			if len(body["PhotoIDs"]) != 2 {
				t.Errorf("expected 2 photo IDs, got %d", len(body["PhotoIDs"]))
			}
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL)
	albumID, err := adapter.CreateAlbum(context.Background(), "Vacation 2024", []string{"proton-1", "proton-2"})
	if err != nil {
		t.Fatalf("CreateAlbum failed: %v", err)
	}
	if albumID != "album-abc" {
		t.Fatalf("expected album-abc, got %s", albumID)
	}
	if createCalls != 1 {
		t.Errorf("expected 1 create call, got %d", createCalls)
	}
	if photosCalls != 1 {
		t.Errorf("expected 1 photos call, got %d", photosCalls)
	}
}

func TestAlbumAdapterCreateAlbumEmptyFileIDs(t *testing.T) {
	var photosCalls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/photos/v1/albums":
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-empty", Name: "Empty"},
			}); err != nil {
				t.Fatalf("encoding response: %v", err)
			}
		default:
			photosCalls++
			t.Errorf("should not call photos endpoint for empty fileIDs, got %s", r.URL.Path)
			w.WriteHeader(http.StatusInternalServerError)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL)
	albumID, err := adapter.CreateAlbum(context.Background(), "Empty", nil)
	if err != nil {
		t.Fatalf("CreateAlbum failed: %v", err)
	}
	if albumID != "album-empty" {
		t.Fatalf("expected album-empty, got %s", albumID)
	}
	if photosCalls != 0 {
		t.Errorf("expected 0 photos calls, got %d", photosCalls)
	}
}

func TestAlbumAdapterCreateAlbumEmptyName(t *testing.T) {
	adapter := newTestAlbumAdapter(t, "http://127.0.0.1:1")
	_, err := adapter.CreateAlbum(context.Background(), "", []string{"x"})
	if err == nil {
		t.Fatal("expected error for empty name")
	}
}

func TestAlbumAdapterCreateAlbumMissingAlbumID(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(createAlbumResponse{Code: 1000, Album: nil}); err != nil {
			t.Fatalf("encoding response: %v", err)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL)
	_, err := adapter.CreateAlbum(context.Background(), "Bad", nil)
	if err == nil {
		t.Fatal("expected error when response has no album ID")
	}
}

func TestAlbumAdapterCreateAlbumNameConflict(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		if _, err := w.Write([]byte(`{"Code":2500,"Error":"album name already exists"}`)); err != nil {
			t.Fatalf("writing response: %v", err)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL)
	_, err := adapter.CreateAlbum(context.Background(), "Dup", nil)
	if err == nil {
		t.Fatal("expected error for 409")
	}
	if !strings.Contains(err.Error(), "409") {
		t.Errorf("expected error to mention 409, got: %v", err)
	}
}

func TestAlbumAdapterCreateAlbumRateLimitRetries(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&attempts, 1)
		if n < 3 {
			w.Header().Set("Retry-After", "0")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		if err := json.NewEncoder(w).Encode(createAlbumResponse{
			Code:  1000,
			Album: &albumResult{ID: "album-after-retry", Name: "Retry"},
		}); err != nil {
			t.Fatalf("encoding response: %v", err)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL, WithAlbumRetryConfig(5, 1*time.Millisecond, 5*time.Millisecond))
	albumID, err := adapter.CreateAlbum(context.Background(), "Retry", nil)
	if err != nil {
		t.Fatalf("CreateAlbum failed after retries: %v", err)
	}
	if albumID != "album-after-retry" {
		t.Fatalf("expected album-after-retry, got %s", albumID)
	}
	if got := atomic.LoadInt32(&attempts); got != 3 {
		t.Errorf("expected 3 attempts, got %d", got)
	}
}

func TestAlbumAdapterCreateAlbumExhaustsRetries(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL, WithAlbumRetryConfig(2, 1*time.Millisecond, 5*time.Millisecond))
	_, err := adapter.CreateAlbum(context.Background(), "Doomed", nil)
	if err == nil {
		t.Fatal("expected error after exhausting retries")
	}
	if !strings.Contains(err.Error(), "exhausted") {
		t.Errorf("expected error to mention exhaustion, got: %v", err)
	}
}

func TestAlbumAdapterCreateAlbumNoRetryOn4xx(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&attempts, 1)
		w.WriteHeader(http.StatusBadRequest)
		if _, err := w.Write([]byte(`{"Code":1001,"Error":"bad request"}`)); err != nil {
			t.Fatalf("writing response: %v", err)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL)
	_, err := adapter.CreateAlbum(context.Background(), "Bad", nil)
	if err == nil {
		t.Fatal("expected error for 400")
	}
	if got := atomic.LoadInt32(&attempts); got != 1 {
		t.Errorf("expected 1 attempt (no retry on 400), got %d", got)
	}
}

func TestAlbumAdapterCreateAlbumContextCancelled(t *testing.T) {
	sleepCh := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	dir := t.TempDir()
	store := NewCredentialStore(dir)
	if err := store.Save(CredentialData{UID: "u", AccessToken: "t"}); err != nil {
		t.Fatal(err)
	}

	adapter := NewAlbumAdapter(store, "x",
		WithAlbumAPIBase(server.URL),
		WithAlbumRetryConfig(5, 1*time.Millisecond, 5*time.Millisecond),
		WithAlbumClock(time.Now, func(ctx context.Context, _ time.Duration) error {
			select {
			case sleepCh <- struct{}{}:
			default:
			}
			<-ctx.Done()
			return ctx.Err()
		}),
	)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-sleepCh
		cancel()
	}()

	_, err := adapter.CreateAlbum(ctx, "Cancel", nil)
	if err == nil {
		t.Fatal("expected error when context cancelled")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("expected context.Canceled, got: %v", err)
	}
}

func TestAlbumAdapterCreateAlbumSequentialDoesNotRateLimit(t *testing.T) {
	var count int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&count, 1)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/photos/v1/albums":
			n := atomic.LoadInt32(&count)
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: fmt.Sprintf("album-%d", n), Name: "X"},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL, WithAlbumRetryConfig(0, 1*time.Millisecond, 5*time.Millisecond))
	for i := 0; i < 50; i++ {
		albumID, err := adapter.CreateAlbum(context.Background(), fmt.Sprintf("Album-%d", i), []string{"p1"})
		if err != nil {
			t.Fatalf("album %d failed: %v", i, err)
		}
		if albumID == "" {
			t.Fatalf("album %d returned empty ID", i)
		}
	}
	if got := atomic.LoadInt32(&count); got != 100 {
		t.Errorf("expected 100 calls (50 create + 50 photos), got %d", got)
	}
}

func TestAlbumAdapterCreateAlbumNetworkError(t *testing.T) {
	adapter := newTestAlbumAdapter(t, "http://127.0.0.1:1", WithAlbumRetryConfig(0, 1*time.Millisecond, 5*time.Millisecond))
	_, err := adapter.CreateAlbum(context.Background(), "Network", nil)
	if err == nil {
		t.Fatal("expected network error")
	}
}

func TestAlbumAdapterIdempotentAddPhotos(t *testing.T) {
	var photosCalls int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/photos/v1/albums":
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-idemp", Name: "Idemp"},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
		case "/photos/v1/albums/album-idemp/photos":
			atomic.AddInt32(&photosCalls, 1)
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL)
	// Calling twice with the same fileIDs simulates the idempotent re-add
	// scenario.  Proton Photos is expected to deduplicate by file hash, so the
	// adapter should treat this as a normal call and not retry/error.
	for i := 0; i < 2; i++ {
		_, err := adapter.CreateAlbum(context.Background(), "Idemp", []string{"proton-1", "proton-2"})
		if err != nil {
			t.Fatalf("call %d failed: %v", i, err)
		}
	}
	if got := atomic.LoadInt32(&photosCalls); got != 2 {
		t.Errorf("expected 2 photos calls, got %d", got)
	}
}

func TestAlbumAdapterParseRetryAfterHeader(t *testing.T) {
	if got := parseRetryAfter("0"); got != 0 {
		t.Errorf("parseRetryAfter(0) = %v, want 0", got)
	}
	if got := parseRetryAfter("5"); got != 5*time.Second {
		t.Errorf("parseRetryAfter(5) = %v, want 5s", got)
	}
	if got := parseRetryAfter(""); got != 0 {
		t.Errorf("parseRetryAfter(\"\") = %v, want 0", got)
	}
	if got := parseRetryAfter("garbage"); got != 0 {
		t.Errorf("parseRetryAfter(garbage) = %v, want 0", got)
	}
}

func TestAlbumAdapterNextBackoffDoubles(t *testing.T) {
	if got := nextBackoff(1*time.Second, 30*time.Second); got != 2*time.Second {
		t.Errorf("nextBackoff(1s) = %v, want 2s", got)
	}
	if got := nextBackoff(20*time.Second, 30*time.Second); got != 30*time.Second {
		t.Errorf("nextBackoff(20s, max=30s) = %v, want 30s", got)
	}
	if got := nextBackoff(50*time.Second, 30*time.Second); got != 30*time.Second {
		t.Errorf("nextBackoff(50s, max=30s) = %v, want 30s", got)
	}
}

func TestAlbumAdapterHonoursRetryAfterHeader(t *testing.T) {
	var (
		createCalls int32
		photosCalls int32
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/photos/v1/albums":
			atomic.AddInt32(&createCalls, 1)
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-ra", Name: "RA"},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
		case "/photos/v1/albums/album-ra/photos":
			n := atomic.AddInt32(&photosCalls, 1)
			if n == 1 {
				w.Header().Set("Retry-After", "2")
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	const retryAfter = 2 * time.Second
	sleeps := make(chan time.Duration, 4)
	dir := t.TempDir()
	store := NewCredentialStore(dir)
	if err := store.Save(CredentialData{UID: "u", AccessToken: "t"}); err != nil {
		t.Fatal(err)
	}
	adapter := NewAlbumAdapter(store, "x",
		WithAlbumAPIBase(server.URL),
		WithAlbumRetryConfig(3, retryAfter, 10*time.Second),
		WithAlbumClock(time.Now, func(_ context.Context, d time.Duration) error {
			sleeps <- d
			return nil
		}),
	)

	if _, err := adapter.CreateAlbum(context.Background(), "RA", []string{"p1"}); err != nil {
		t.Fatalf("CreateAlbum failed: %v", err)
	}
	close(sleeps)
	var observed time.Duration
	for d := range sleeps {
		if d > observed {
			observed = d
		}
	}
	if observed < retryAfter {
		t.Errorf("expected sleep >= %s (Retry-After value), got %s", retryAfter, observed)
	}
	if got := atomic.LoadInt32(&photosCalls); got != 2 {
		t.Errorf("expected 2 photos calls (1 retry), got %d", got)
	}
}

func TestAlbumAdapterRetriesUseExponentialBackoffWhenHeaderAbsent(t *testing.T) {
	var photosCalls int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/photos/v1/albums":
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-eb", Name: "EB"},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
		default:
			n := atomic.AddInt32(&photosCalls, 1)
			if n < 3 {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer server.Close()

	var sleeps []time.Duration
	var mu sync.Mutex
	adapter := newTestAlbumAdapter(t, server.URL,
		WithAlbumRetryConfig(3, 5*time.Millisecond, 80*time.Millisecond),
		WithAlbumClock(time.Now, func(_ context.Context, d time.Duration) error {
			mu.Lock()
			sleeps = append(sleeps, d)
			mu.Unlock()
			return nil
		}),
	)

	if _, err := adapter.CreateAlbum(context.Background(), "EB", []string{"p1"}); err != nil {
		t.Fatalf("CreateAlbum failed: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(sleeps) < 2 {
		t.Fatalf("expected at least 2 sleeps (recoverable 5xx), got %d", len(sleeps))
	}
	for _, d := range sleeps {
		if d > 80*time.Millisecond {
			t.Errorf("sleep exceeded maxBackoff (80ms): %s", d)
		}
	}
}

func TestAlbumAdapterRollsBackAlbumWhenAddPhotosFails(t *testing.T) {
	var (
		deleteCalls int32
	)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/photos/v1/albums":
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-rb", Name: "RB"},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
		case "/photos/v1/albums/album-rb/photos":
			w.WriteHeader(http.StatusBadRequest)
			if _, err := w.Write([]byte(`{"Code":1001,"Error":"bad request"}`)); err != nil {
				t.Fatalf("writing: %v", err)
			}
		case "/photos/v1/albums/album-rb":
			if r.Method != http.MethodDelete {
				t.Errorf("expected DELETE for rollback, got %s", r.Method)
			}
			atomic.AddInt32(&deleteCalls, 1)
			w.WriteHeader(http.StatusOK)
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL, WithAlbumRetryConfig(0, 1*time.Millisecond, 5*time.Millisecond))
	albumID, err := adapter.CreateAlbum(context.Background(), "RB", []string{"p1"})
	if err == nil {
		t.Fatal("expected error when addPhotos fails")
	}
	if !strings.Contains(err.Error(), "rolled back") {
		t.Errorf("expected rollback message, got: %v", err)
	}
	if albumID != "album-rb" {
		t.Errorf("expected albumID even on rollback failure, got %q", albumID)
	}
	if got := atomic.LoadInt32(&deleteCalls); got != 1 {
		t.Errorf("expected 1 rollback DELETE, got %d", got)
	}
}

func TestAlbumAdapterPreservesAlbumOnRollbackFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/photos/v1/albums":
			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "album-keep", Name: "Keep"},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
		case "/photos/v1/albums/album-keep/photos":
			w.WriteHeader(http.StatusBadRequest)
		case "/photos/v1/albums/album-keep":
			w.WriteHeader(http.StatusInternalServerError)
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL, WithAlbumRetryConfig(0, 1*time.Millisecond, 5*time.Millisecond))
	_, err := adapter.CreateAlbum(context.Background(), "Keep", []string{"p1"})
	if err == nil {
		t.Fatal("expected error when both addPhotos and rollback fail")
	}
	if !strings.Contains(err.Error(), "album exists without photos") {
		t.Errorf("expected 'album exists without photos' message, got: %v", err)
	}
}

func TestAlbumAdapterWithAlbumRetryConfigClampsNegativeValues(t *testing.T) {
	dir := t.TempDir()
	store := NewCredentialStore(dir)
	if err := store.Save(CredentialData{UID: "u", AccessToken: "t"}); err != nil {
		t.Fatal(err)
	}
	adapter := NewAlbumAdapter(store, "x",
		WithAlbumAPIBase("http://example.invalid"),
		WithAlbumRetryConfig(-1, -5*time.Second, -10*time.Second),
	)
	if adapter.maxRetries != 0 {
		t.Errorf("expected maxRetries clamped to 0, got %d", adapter.maxRetries)
	}
	if adapter.initialBackoff != 0 {
		t.Errorf("expected initialBackoff clamped to 0, got %s", adapter.initialBackoff)
	}
	if adapter.maxBackoff != 0 {
		t.Errorf("expected maxBackoff clamped to 0, got %s", adapter.maxBackoff)
	}
}

func TestAlbumAdapterAttachToUploader(t *testing.T) {
	t.Skip("Uploader requires live Proton credentials; covered by integration tests")
}

func TestAlbumAdapterConcurrentAlbumsSequential(t *testing.T) {
	var mu sync.Mutex
	calls := make(map[string]int)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/photos/v1/albums" {
			var body map[string]string
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatalf("decoding body: %v", err)
			}
			mu.Lock()
			calls[body["Name"]]++
			mu.Unlock()
			if err := json.NewEncoder(w).Encode(createAlbumResponse{
				Code:  1000,
				Album: &albumResult{ID: "a-" + body["Name"], Name: body["Name"]},
			}); err != nil {
				t.Fatalf("encoding: %v", err)
			}
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	adapter := newTestAlbumAdapter(t, server.URL, WithAlbumRetryConfig(0, 1*time.Millisecond, 5*time.Millisecond))
	const total = 50
	var wg sync.WaitGroup
	for i := 0; i < total; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := adapter.CreateAlbum(context.Background(), fmt.Sprintf("Album-%d", i), []string{"p1"})
			if err != nil {
				t.Errorf("album %d failed: %v", i, err)
			}
		}(i)
	}
	wg.Wait()
	mu.Lock()
	defer mu.Unlock()
	if len(calls) < total {
		t.Errorf("expected at least %d distinct album names, got %d", total, len(calls))
	}
}

// Required to keep the io import used if all read paths are stubbed.
var _ = io.Discard
