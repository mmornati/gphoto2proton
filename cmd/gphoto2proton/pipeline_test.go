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
package main

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
	"github.com/mmornati/gphoto2proton/internal/takeout"
)

type fakeReader struct {
	mu            sync.Mutex
	media         []domain.Media
	mediaData     map[string][]byte
	albums        []domain.Album
	albumErr      error
	nextErr       error
	manifestCalls int
	nextCalls     int
}

func (f *fakeReader) Next(ctx context.Context) (*domain.Media, io.ReadCloser, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextCalls++
	if f.nextErr != nil {
		return nil, nil, f.nextErr
	}
	if len(f.media) == 0 {
		return nil, nil, io.EOF
	}
	media := f.media[0]
	f.media = f.media[1:]
	data := f.mediaData[media.Filename]
	return &media, io.NopCloser(bytes.NewReader(data)), nil
}

func (f *fakeReader) AlbumManifest(ctx context.Context) ([]domain.Album, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.manifestCalls++
	if f.albumErr != nil {
		return nil, f.albumErr
	}
	out := make([]domain.Album, len(f.albums))
	copy(out, f.albums)
	return out, nil
}

type fakeUploader struct {
	mu          sync.Mutex
	uploads     []string
	albums      []fakeAlbumCall
	failOnName  string
	failOnAlbum string
	albumErr    error
}

type fakeAlbumCall struct {
	Name    string
	FileIDs []string
}

func (u *fakeUploader) Upload(ctx context.Context, name string, r io.Reader) (string, error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.failOnName != "" && u.failOnName == name {
		return "", errors.New("upload failed for " + name)
	}
	if _, err := io.Copy(io.Discard, r); err != nil {
		return "", err
	}
	u.uploads = append(u.uploads, name)
	return "fileID-" + name, nil
}

func (u *fakeUploader) CreateAlbum(ctx context.Context, name string, fileIDs []string) (string, error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.albumErr != nil {
		return "", u.albumErr
	}
	if u.failOnAlbum != "" && u.failOnAlbum == name {
		return "", errors.New("album creation failed for " + name)
	}
	cp := make([]string, len(fileIDs))
	copy(cp, fileIDs)
	u.albums = append(u.albums, fakeAlbumCall{Name: name, FileIDs: cp})
	return "albumID-" + name, nil
}

var _ port.ProtonUploader = (*fakeUploader)(nil)
var _ port.TakeoutReader = (*fakeReader)(nil)

func TestPipelineRequiresReader(t *testing.T) {
	p := &Pipeline{}
	err := p.Run(context.Background())
	if err == nil {
		t.Fatal("expected error when reader is nil")
	}
}

func TestPipelineProcessesAllMedia(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
			{Filename: "b.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a-data"),
			"b.jpg": []byte("b-data"),
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.uploads) != 2 {
		t.Fatalf("expected 2 uploads, got %d", len(u.uploads))
	}
	if u.uploads[0] != "a.jpg" || u.uploads[1] != "b.jpg" {
		t.Fatalf("unexpected upload order: %v", u.uploads)
	}
}

func TestPipelineCallsAlbumManifestPostUpload(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a-data"),
		},
		albums: []domain.Album{
			{Name: "Album1", FileIDs: []string{"a.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if r.nextCalls != 2 {
		t.Fatalf("expected Next called twice (once returning EOF), got %d", r.nextCalls)
	}
	if r.manifestCalls != 1 {
		t.Fatalf("expected AlbumManifest called once, got %d", r.manifestCalls)
	}
}

func TestPipelineInvokesAlbumHandler(t *testing.T) {
	r := &fakeReader{
		albums: []domain.Album{
			{Name: "Album1", FileIDs: []string{"a.jpg"}},
			{Name: "Album2", FileIDs: []string{"b.jpg"}},
		},
	}
	var handlerCalls int
	var seenAlbums []domain.Album
	handler := func(ctx context.Context, albums []domain.Album) error {
		handlerCalls++
		seenAlbums = albums
		return nil
	}
	p := &Pipeline{Reader: r, OnAlbums: handler}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if handlerCalls != 1 {
		t.Fatalf("expected handler called once, got %d", handlerCalls)
	}
	if len(seenAlbums) != 2 {
		t.Fatalf("expected handler to see 2 albums, got %d", len(seenAlbums))
	}
}

func TestPipelinePropagatesUploadError(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
			{Filename: "b.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a-data"),
			"b.jpg": []byte("b-data"),
		},
	}
	u := &fakeUploader{failOnName: "a.jpg"}
	p := &Pipeline{Reader: r, Uploader: u}

	err := p.Run(context.Background())
	if err == nil {
		t.Fatal("expected error from upload failure")
	}
}

func TestPipelineReturnsReaderError(t *testing.T) {
	r := &fakeReader{nextErr: errors.New("boom")}
	p := &Pipeline{Reader: r}

	err := p.Run(context.Background())
	if err == nil {
		t.Fatal("expected error from reader")
	}
}

func TestPipelineReturnsManifestError(t *testing.T) {
	r := &fakeReader{albumErr: errors.New("manifest boom")}
	p := &Pipeline{Reader: r}

	err := p.Run(context.Background())
	if err == nil {
		t.Fatal("expected error from manifest")
	}
}

func TestPipelineReturnsHandlerError(t *testing.T) {
	r := &fakeReader{
		albums: []domain.Album{{Name: "X", FileIDs: []string{"a.jpg"}}},
	}
	handler := func(ctx context.Context, albums []domain.Album) error {
		return errors.New("handler boom")
	}
	p := &Pipeline{Reader: r, OnAlbums: handler}

	err := p.Run(context.Background())
	if err == nil {
		t.Fatal("expected error from handler")
	}
}

func TestPipelineNoMediaStillCallsManifest(t *testing.T) {
	r := &fakeReader{}
	handlerCalls := 0
	handler := func(ctx context.Context, albums []domain.Album) error {
		handlerCalls++
		if len(albums) != 0 {
			t.Fatalf("expected handler to receive 0 albums, got %d", len(albums))
		}
		return nil
	}
	p := &Pipeline{Reader: r, OnAlbums: handler}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if handlerCalls != 1 {
		t.Fatalf("expected handler called once even without media, got %d", handlerCalls)
	}
	if r.manifestCalls != 1 {
		t.Fatalf("expected AlbumManifest called once, got %d", r.manifestCalls)
	}
}

func TestPipelineIntegrationWithRealTakeoutReader(t *testing.T) {
	albumJSON := []byte(`{"albumData":{"title":"RealAlbum","date":{"timestamp":"1625097600"},"albumItems":[{"title":"IMG_0001.JPG"}]}}`)
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	files := map[string][]byte{
		"Takeout/IMG_0001.JPG":      []byte("img-data"),
		"Takeout/IMG_0001.JPG.json": []byte(`{"title":"IMG_0001.JPG"}`),
		"Takeout/album.json":        albumJSON,
	}
	names := []string{
		"Takeout/IMG_0001.JPG",
		"Takeout/IMG_0001.JPG.json",
		"Takeout/album.json",
	}
	for _, name := range names {
		content := files[name]
		_ = tw.WriteHeader(&tar.Header{Name: name, Size: int64(len(content)), Mode: 0644})
		_, _ = tw.Write(content)
	}
	tw.Close()

	tmpDir := t.TempDir()
	tarPath := tmpDir + "/takeout.tar"
	if err := os.WriteFile(tarPath, buf.Bytes(), 0644); err != nil {
		t.Fatal(err)
	}

	reader := takeout.NewStreamReader(tarPath)
	u := &fakeUploader{}
	var gotAlbums []domain.Album
	handler := func(ctx context.Context, albums []domain.Album) error {
		gotAlbums = albums
		return nil
	}
	p := &Pipeline{Reader: reader, Uploader: u, OnAlbums: handler}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.uploads) != 1 {
		t.Fatalf("expected 1 upload, got %d", len(u.uploads))
	}
	if u.uploads[0] != "IMG_0001.JPG" {
		t.Fatalf("expected upload of IMG_0001.JPG, got %s", u.uploads[0])
	}
	if len(gotAlbums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(gotAlbums))
	}
	if gotAlbums[0].Name != "RealAlbum" {
		t.Fatalf("expected album RealAlbum, got %s", gotAlbums[0].Name)
	}
}

// --- Story 2.2: Album Recreation in Proton Photos ---

func TestPipelineCreateAlbumsWhenNoHandler(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
			{Filename: "b.jpg"},
			{Filename: "c.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a-data"),
			"b.jpg": []byte("b-data"),
			"c.jpg": []byte("c-data"),
		},
		albums: []domain.Album{
			{Name: "Album1", FileIDs: []string{"a.jpg", "b.jpg"}},
			{Name: "Album2", FileIDs: []string{"c.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 2 {
		t.Fatalf("expected 2 album create calls, got %d", len(u.albums))
	}
	byName := map[string]fakeAlbumCall{}
	for _, a := range u.albums {
		byName[a.Name] = a
	}
	if a, ok := byName["Album1"]; !ok {
		t.Fatal("Album1 not created")
	} else if len(a.FileIDs) != 2 {
		t.Errorf("Album1 expected 2 file IDs, got %d", len(a.FileIDs))
	}
	if a, ok := byName["Album2"]; !ok {
		t.Fatal("Album2 not created")
	} else if len(a.FileIDs) != 1 {
		t.Errorf("Album2 expected 1 file ID, got %d", len(a.FileIDs))
	}
}

func TestPipelineCreateAlbumsMapsTakeoutToProtonFileIDs(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "takeout-a.jpg"},
		},
		mediaData: map[string][]byte{
			"takeout-a.jpg": []byte("a-data"),
		},
		albums: []domain.Album{
			{Name: "Mapped", FileIDs: []string{"takeout-a.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 1 {
		t.Fatalf("expected 1 album create call, got %d", len(u.albums))
	}
	if len(u.albums[0].FileIDs) != 1 || u.albums[0].FileIDs[0] != "fileID-takeout-a.jpg" {
		t.Errorf("expected Proton file ID 'fileID-takeout-a.jpg', got %v", u.albums[0].FileIDs)
	}
}

func TestPipelineCreateAlbumsPhotoInMultipleAlbums(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "shared.jpg"},
		},
		mediaData: map[string][]byte{
			"shared.jpg": []byte("x"),
		},
		albums: []domain.Album{
			{Name: "AlbumA", FileIDs: []string{"shared.jpg"}},
			{Name: "AlbumB", FileIDs: []string{"shared.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 2 {
		t.Fatalf("expected 2 album create calls, got %d", len(u.albums))
	}
	expectedID := "fileID-shared.jpg"
	for _, a := range u.albums {
		if len(a.FileIDs) != 1 || a.FileIDs[0] != expectedID {
			t.Errorf("album %s expected file IDs [%s], got %v", a.Name, expectedID, a.FileIDs)
		}
	}
}

func TestPipelineCreateAlbumsContinuesOnError(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
			{Filename: "b.jpg"},
			{Filename: "c.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a"),
			"b.jpg": []byte("b"),
			"c.jpg": []byte("c"),
		},
		albums: []domain.Album{
			{Name: "AlbumA", FileIDs: []string{"a.jpg"}},
			{Name: "AlbumB", FileIDs: []string{"b.jpg"}},
			{Name: "AlbumC", FileIDs: []string{"c.jpg"}},
		},
	}
	u := &fakeUploader{failOnAlbum: "AlbumB"}
	var loggerBuf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&loggerBuf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	p := &Pipeline{Reader: r, Uploader: u, Logger: logger}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 2 {
		t.Fatalf("expected 2 albums created (AlbumB should fail), got %d", len(u.albums))
	}
	names := []string{}
	for _, a := range u.albums {
		names = append(names, a.Name)
	}
	if !containsString(names, "AlbumA") {
		t.Error("AlbumA should be created")
	}
	if !containsString(names, "AlbumC") {
		t.Error("AlbumC should be created even after AlbumB fails")
	}
	if !strings.Contains(loggerBuf.String(), "album creation failed") {
		t.Errorf("expected error to be logged, got: %s", loggerBuf.String())
	}
}

func TestPipelineCreateAlbumsSkipsEmptyAlbum(t *testing.T) {
	r := &fakeReader{
		albums: []domain.Album{
			{Name: "EmptyAlbum", FileIDs: []string{}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 0 {
		t.Errorf("expected no albums created for empty album, got %d", len(u.albums))
	}
}

func TestPipelineCreateAlbumsSkipsAlbumWithUnmappedPhotos(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a"),
		},
		albums: []domain.Album{
			{Name: "BadAlbum", FileIDs: []string{"missing.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 0 {
		t.Errorf("expected no albums created when photo mapping fails, got %d", len(u.albums))
	}
}

func TestPipelineCreateAlbumsRecordsState(t *testing.T) {
	tracker := &fakeStateTracker{}
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a"),
		},
		albums: []domain.Album{
			{Name: "Album1", FileIDs: []string{"a.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u, State: tracker}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tracker.records) != 1 {
		t.Fatalf("expected 1 state record, got %d", len(tracker.records))
	}
	if tracker.records[0].fileID != "albumID-Album1" {
		t.Errorf("expected record for albumID-Album1, got %q", tracker.records[0].fileID)
	}
	if tracker.records[0].state != domain.StateAlbumAttached {
		t.Errorf("expected StateAlbumAttached=%d, got %d", domain.StateAlbumAttached, tracker.records[0].state)
	}
}

func TestPipelineCreateAlbumsSequentialNoRateLimit(t *testing.T) {
	albums := make([]domain.Album, 50)
	for i := range albums {
		albums[i] = domain.Album{
			Name:    fmt.Sprintf("Album%d", i),
			FileIDs: []string{"a.jpg"},
		}
	}
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a"),
		},
		albums: albums,
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 50 {
		t.Errorf("expected 50 albums created, got %d", len(u.albums))
	}
}

func TestPipelineCreateAlbumsSkipsDuplicateFileIDs(t *testing.T) {
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a"),
		},
		albums: []domain.Album{
			{Name: "Dups", FileIDs: []string{"a.jpg", "a.jpg", "a.jpg"}},
		},
	}
	u := &fakeUploader{}
	p := &Pipeline{Reader: r, Uploader: u}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(u.albums))
	}
	if len(u.albums[0].FileIDs) != 1 {
		t.Errorf("expected 1 unique Proton file ID, got %d", len(u.albums[0].FileIDs))
	}
}

func TestPipelineCreateAlbumsNoUploaderIsNoOp(t *testing.T) {
	r := &fakeReader{
		albums: []domain.Album{
			{Name: "Album1", FileIDs: []string{"a.jpg"}},
		},
	}
	p := &Pipeline{Reader: r}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestPipelineCreateAlbumsStateRecordFailureDoesNotAbort(t *testing.T) {
	tracker := &fakeStateTracker{recordErr: errors.New("db locked")}
	r := &fakeReader{
		media: []domain.Media{
			{Filename: "a.jpg"},
		},
		mediaData: map[string][]byte{
			"a.jpg": []byte("a"),
		},
		albums: []domain.Album{
			{Name: "Album1", FileIDs: []string{"a.jpg"}},
		},
	}
	u := &fakeUploader{}
	var loggerBuf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&loggerBuf, nil))
	p := &Pipeline{Reader: r, Uploader: u, State: tracker, Logger: logger}

	if err := p.Run(context.Background()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(u.albums) != 1 {
		t.Errorf("expected 1 album created, got %d", len(u.albums))
	}
	if !strings.Contains(loggerBuf.String(), "recording album state failed") {
		t.Errorf("expected state-failure warning to be logged, got: %s", loggerBuf.String())
	}
}

// --- helpers ---

func containsString(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

type fakeStateTracker struct {
	mu        sync.Mutex
	records   []fakeStateRecord
	recordErr error
}

type fakeStateRecord struct {
	fileID string
	state  domain.State
}

func (f *fakeStateTracker) Init(ctx context.Context, sessionID string) error { return nil }
func (f *fakeStateTracker) Record(ctx context.Context, fileID string, state domain.State) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.recordErr != nil {
		return f.recordErr
	}
	f.records = append(f.records, fakeStateRecord{fileID: fileID, state: state})
	return nil
}
func (f *fakeStateTracker) RecordAlbum(ctx context.Context, albumID string, state domain.State) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.recordErr != nil {
		return f.recordErr
	}
	f.records = append(f.records, fakeStateRecord{fileID: albumID, state: state})
	return nil
}
func (f *fakeStateTracker) FileStates(ctx context.Context, sessionID string) ([]port.FileEntry, error) {
	return nil, nil
}
func (f *fakeStateTracker) Close() error { return nil }

var _ port.StateTracker = (*fakeStateTracker)(nil)
