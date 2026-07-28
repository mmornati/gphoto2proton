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
	"io"
	"os"
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
	mu         sync.Mutex
	uploads    []string
	failOnName string
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
		tw.WriteHeader(&tar.Header{Name: name, Size: int64(len(content)), Mode: 0644})
		tw.Write(content)
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
