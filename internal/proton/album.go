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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

const (
	defaultAlbumAPIBase        = "https://photos-api.proton.me"
	defaultAlbumMaxRetries     = 5
	defaultAlbumInitialBackoff = 1 * time.Second
	defaultAlbumMaxBackoff     = 30 * time.Second
)

// AlbumAdapter creates Proton Photos albums via the Proton Photos API.
// It is the album counterpart of the Proton Drive uploader. The Proton-API-Bridge
// does not expose album creation, so this adapter speaks HTTP directly to the
// undocumented Proton Photos service. Endpoints and request/response shapes are
// derived from the Story 1.6 probe plan; they are intentionally kept in
// configurable form so the adapter can be retargeted when the API changes.
type AlbumAdapter struct {
	apiBase        string
	httpClient     *http.Client
	credStore      *CredentialStore
	username       string
	maxRetries     int
	initialBackoff time.Duration
	maxBackoff     time.Duration
	now            func() time.Time
	sleep          func(context.Context, time.Duration) error
}

// AlbumAdapterOption configures an AlbumAdapter.
type AlbumAdapterOption func(*AlbumAdapter)

// WithAlbumAPIBase overrides the Proton Photos API base URL. Used in tests
// to point the adapter at a local httptest server.
func WithAlbumAPIBase(url string) AlbumAdapterOption {
	return func(a *AlbumAdapter) { a.apiBase = url }
}

// WithAlbumHTTPClient overrides the HTTP client. Used in tests.
func WithAlbumHTTPClient(client *http.Client) AlbumAdapterOption {
	return func(a *AlbumAdapter) { a.httpClient = client }
}

// WithAlbumRetryConfig overrides the retry/backoff settings.
func WithAlbumRetryConfig(maxRetries int, initialBackoff, maxBackoff time.Duration) AlbumAdapterOption {
	return func(a *AlbumAdapter) {
		if maxRetries < 0 {
			maxRetries = 0
		}
		if initialBackoff < 0 {
			initialBackoff = 0
		}
		if maxBackoff < 0 {
			maxBackoff = 0
		}
		a.maxRetries = maxRetries
		a.initialBackoff = initialBackoff
		a.maxBackoff = maxBackoff
	}
}

// WithAlbumClock overrides the clock and sleep function. Used in tests to
// avoid real time-based delays.
func WithAlbumClock(now func() time.Time, sleep func(context.Context, time.Duration) error) AlbumAdapterOption {
	return func(a *AlbumAdapter) {
		if now != nil {
			a.now = now
		}
		if sleep != nil {
			a.sleep = sleep
		}
	}
}

// NewAlbumAdapter constructs an AlbumAdapter using the supplied credentials.
// The credential store is consulted at call time so refreshed sessions are
// picked up automatically.
func NewAlbumAdapter(credStore *CredentialStore, username string, opts ...AlbumAdapterOption) *AlbumAdapter {
	a := &AlbumAdapter{
		apiBase:        defaultAlbumAPIBase,
		httpClient:     &http.Client{Timeout: 30 * time.Second},
		credStore:      credStore,
		username:       username,
		maxRetries:     defaultAlbumMaxRetries,
		initialBackoff: defaultAlbumInitialBackoff,
		maxBackoff:     defaultAlbumMaxBackoff,
		now:            time.Now,
		sleep:          contextSleep,
	}
	for _, opt := range opts {
		opt(a)
	}
	return a
}

func contextSleep(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return nil
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// CreateAlbum creates a Proton Photos album with the given name and attaches
// the supplied Proton file IDs to it. The album is created in two phases:
//  1. POST /photos/v1/albums with the name. The response is parsed for the
//     newly assigned album ID.
//  2. POST /photos/v1/albums/{albumID}/photos with the photo IDs. This step
//     is skipped when fileIDs is empty.
//
// Both calls honour Proton rate limits (HTTP 429) with exponential backoff:
// 1s, 2s, 4s, 8s, up to 30s. Network errors and 5xx responses are also
// retried. 4xx client errors (other than 429) are returned immediately
// because they signal a programmer mistake that retrying will not fix. If
// attaching photos fails, the adapter attempts to delete the newly created
// album so failed creation does not leave an empty album behind.
func (a *AlbumAdapter) CreateAlbum(ctx context.Context, name string, fileIDs []string) (string, error) {
	if name == "" {
		return "", errors.New("album: name is required")
	}

	albumID, err := a.createAlbum(ctx, name)
	if err != nil {
		return "", err
	}

	if len(fileIDs) == 0 {
		return albumID, nil
	}

	if err := a.addPhotosToAlbum(ctx, albumID, fileIDs); err != nil {
		rollbackErr := a.deleteAlbum(ctx, albumID)
		if rollbackErr != nil {
			return albumID, fmt.Errorf(
				"album: attaching photos to %s failed; album exists without photos because rollback failed: %w",
				albumID,
				errors.Join(err, rollbackErr),
			)
		}
		return albumID, fmt.Errorf("album: attaching photos to %s failed; album rolled back: %w", albumID, err)
	}
	return albumID, nil
}

func (a *AlbumAdapter) createAlbum(ctx context.Context, name string) (string, error) {
	body, err := json.Marshal(map[string]string{"Name": name})
	if err != nil {
		return "", fmt.Errorf("album: encoding request: %w", err)
	}

	var resp createAlbumResponse
	if err := a.doRequest(ctx, "/photos/v1/albums", body, &resp); err != nil {
		return "", fmt.Errorf("album: creating %q: %w", name, err)
	}
	if resp.Album == nil || resp.Album.ID == "" {
		return "", fmt.Errorf("album: response missing album ID for %q", name)
	}
	return resp.Album.ID, nil
}

func (a *AlbumAdapter) addPhotosToAlbum(ctx context.Context, albumID string, fileIDs []string) error {
	body, err := json.Marshal(map[string][]string{"PhotoIDs": fileIDs})
	if err != nil {
		return fmt.Errorf("album: encoding request: %w", err)
	}
	path := fmt.Sprintf("/photos/v1/albums/%s/photos", albumID)
	return a.doRequest(ctx, path, body, nil)
}

func (a *AlbumAdapter) deleteAlbum(ctx context.Context, albumID string) error {
	path := fmt.Sprintf("/photos/v1/albums/%s", albumID)
	return a.doRequestMethod(ctx, http.MethodDelete, path, nil, nil)
}

func (a *AlbumAdapter) doRequest(ctx context.Context, path string, body []byte, out interface{}) error {
	return a.doRequestMethod(ctx, http.MethodPost, path, body, out)
}

func (a *AlbumAdapter) doRequestMethod(ctx context.Context, method, path string, body []byte, out interface{}) error {
	var lastErr error
	delay := a.initialBackoff
	for attempt := 0; attempt <= a.maxRetries; attempt++ {
		if attempt > 0 {
			if err := a.sleep(ctx, delay); err != nil {
				return err
			}
		}

		err := a.doOnce(ctx, method, path, body, out)
		if err == nil {
			return nil
		}
		lastErr = err
		if !shouldRetry(err) {
			return err
		}

		var retryable *retryableError
		if errors.As(err, &retryable) && retryable.delay > 0 {
			delay = minDuration(retryable.delay, a.maxBackoff)
		} else if attempt > 0 {
			delay = nextBackoff(delay, a.maxBackoff)
		}
	}
	return fmt.Errorf("album: exhausted %d retries: %w", a.maxRetries, lastErr)
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func (a *AlbumAdapter) doOnce(ctx context.Context, method, path string, body []byte, out interface{}) error {
	cred, err := a.credStore.Load()
	if err != nil {
		return fmt.Errorf("album: loading credentials: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, method, a.apiBase+path, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("album: building request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+cred.AccessToken)
	req.Header.Set("x-pm-uid", cred.UID)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "gphoto2proton/1.0")

	resp, err := a.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("album: request failed: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("album: reading response: %w", err)
	}

	if resp.StatusCode == http.StatusTooManyRequests {
		retryAfter := parseRetryAfter(resp.Header.Get("Retry-After"))
		return &retryableError{
			status: resp.StatusCode,
			reason: "rate limited",
			delay:  retryAfter,
		}
	}

	if resp.StatusCode >= 500 {
		return &retryableError{
			status: resp.StatusCode,
			reason: "server error",
			delay:  0,
		}
	}

	if resp.StatusCode >= 400 {
		return &httpStatusError{
			status: resp.StatusCode,
			body:   string(respBody),
		}
	}

	if out != nil && len(respBody) > 0 {
		if err := json.Unmarshal(respBody, out); err != nil {
			return fmt.Errorf("album: decoding response: %w", err)
		}
	}
	return nil
}

type createAlbumResponse struct {
	Code  int          `json:"Code"`
	Album *albumResult `json:"Album"`
}

type albumResult struct {
	ID   string `json:"ID"`
	Name string `json:"Name"`
}

type retryableError struct {
	status int
	reason string
	delay  time.Duration
}

func (e *retryableError) Error() string {
	return fmt.Sprintf("retryable error (status=%d, reason=%s)", e.status, e.reason)
}

type httpStatusError struct {
	status int
	body   string
}

func (e *httpStatusError) Error() string {
	return fmt.Sprintf("http error (status=%d, body=%s)", e.status, e.body)
}

func shouldRetry(err error) bool {
	var retryable *retryableError
	if errors.As(err, &retryable) {
		return true
	}
	return false
}

func nextBackoff(current, max time.Duration) time.Duration {
	doubled := current * 2
	if doubled > max {
		return max
	}
	return doubled
}

func parseRetryAfter(header string) time.Duration {
	if header == "" {
		return 0
	}
	if secs, err := strconv.Atoi(header); err == nil {
		return time.Duration(secs) * time.Second
	}
	if t, err := http.ParseTime(header); err == nil {
		d := time.Until(t)
		if d > 0 {
			return d
		}
	}
	return 0
}
