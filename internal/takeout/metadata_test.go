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
package takeout

import (
	"bytes"
	"strings"
	"testing"
)

func TestParseSidecarAlbumsEmptyAlbumData(t *testing.T) {
	sidecar := []byte(`{"title":"IMG_0001.JPG"}`)
	albums, err := ParseSidecarAlbums(bytes.NewReader(sidecar))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if albums != nil {
		t.Fatalf("expected nil albums, got %v", albums)
	}
}

func TestParseTopLevelAlbumMissingKey(t *testing.T) {
	doc := []byte(`{"title":"no albumData here"}`)
	albums, err := ParseTopLevelAlbum(bytes.NewReader(doc))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if albums != nil {
		t.Fatalf("expected nil albums, got %v", albums)
	}
}

func TestParsePerAlbumJSON(t *testing.T) {
	doc := []byte(`{"title":"Vacation","description":"Beach 2021","coverPhoto":"IMG_0001.JPG","mediaItems":["IMG_0001.JPG","IMG_0002.JPG"]}`)
	album, err := ParsePerAlbumJSON(bytes.NewReader(doc))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if album.Name != "Vacation" {
		t.Fatalf("expected album name 'Vacation', got %q", album.Name)
	}
	if len(album.FileIDs) != 2 {
		t.Fatalf("expected 2 file IDs, got %d", len(album.FileIDs))
	}
}

func TestParsePerAlbumJSONInvalidJSON(t *testing.T) {
	_, err := ParsePerAlbumJSON(strings.NewReader("not json"))
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestParseTopLevelAlbumInvalidJSON(t *testing.T) {
	_, err := ParseTopLevelAlbum(strings.NewReader("not json"))
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestParseSidecarAlbumsInvalidJSON(t *testing.T) {
	_, err := ParseSidecarAlbums(strings.NewReader("not json"))
	if err == nil {
		t.Fatal("expected error for invalid JSON")
	}
}

func TestIsTopLevelAlbumFile(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"album.json", true},
		{"Takeout/album.json", true},
		{"Google Photos/album.json", true},
		{"Google Photos/Albums/Album1/album.json", false},
		{"Takeout/Google Photos/Albums/Album1/album.json", false},
		{"other.json", false},
		{"album.json/foo", false},
	}
	for _, c := range cases {
		got := IsTopLevelAlbumFile(c.path)
		if got != c.want {
			t.Errorf("IsTopLevelAlbumFile(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestIsPerAlbumFile(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"Google Photos/Albums/Album1/album.json", true},
		{"Takeout/Google Photos/Albums/Vacation/album.json", true},
		{"albums/Summer/album.json", true},
		{"album.json", false},
		{"Takeout/album.json", false},
		{"Google Photos/album.json", false},
		{"other.json", false},
	}
	for _, c := range cases {
		got := IsPerAlbumFile(c.path)
		if got != c.want {
			t.Errorf("IsPerAlbumFile(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestIsPhotoSidecar(t *testing.T) {
	cases := []struct {
		path string
		want bool
	}{
		{"Takeout/IMG_0001.JPG.json", true},
		{"Takeout/photo.png.json", true},
		{"Takeout/video.mp4.json", true},
		{"album.json", false},
		{"Google Photos/Albums/Album1/album.json", false},
		{"Takeout/Albums/album-info.json", false},
		{"list.json", false},
		{"some-text.txt", false},
		{"Takeout/IMG_0001.JSON", false},
	}
	for _, c := range cases {
		got := IsPhotoSidecar(c.path)
		if got != c.want {
			t.Errorf("IsPhotoSidecar(%q) = %v, want %v", c.path, got, c.want)
		}
	}
}

func TestParseSidecarAlbumsHandlesArrayFormat(t *testing.T) {
	sidecar := []byte(`{"title":"IMG_0001.JPG","albumData":[{"title":"Album A","albumItems":[{"title":"IMG_0001.JPG"}]},{"title":"Album B","albumItems":[{"title":"IMG_0001.JPG"}]}]}`)
	albums, err := ParseSidecarAlbums(bytes.NewReader(sidecar))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(albums) != 2 {
		t.Fatalf("expected 2 albums, got %d", len(albums))
	}
	names := map[string]bool{}
	for _, a := range albums {
		names[a.Name] = true
	}
	if !names["Album A"] || !names["Album B"] {
		t.Fatalf("expected Album A and Album B in result, got %v", names)
	}
}

func TestParseTopLevelAlbumHandlesArrayFormat(t *testing.T) {
	doc := []byte(`{"albumData":[{"title":"Album A","albumItems":[{"title":"IMG_0001.JPG"}]},{"title":"Album B","albumItems":[{"title":"IMG_0002.JPG"}]}]}`)
	albums, err := ParseTopLevelAlbum(bytes.NewReader(doc))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(albums) != 2 {
		t.Fatalf("expected 2 albums, got %d", len(albums))
	}
}

func TestParseTopLevelAlbumParsesCreatedAt(t *testing.T) {
	doc := []byte(`{"albumData":{"title":"Dated","date":{"timestamp":"1625097600"},"albumItems":[]}}`)
	albums, err := ParseTopLevelAlbum(bytes.NewReader(doc))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(albums))
	}
	if albums[0].CreatedAt.IsZero() {
		t.Fatal("expected CreatedAt set, got zero")
	}
}

func TestMergeFileIDsDedup(t *testing.T) {
	a := []string{"a", "b"}
	b := []string{"b", "c"}
	got := mergeFileIDs(a, b)
	want := []string{"a", "b", "c"}
	if len(got) != len(want) {
		t.Fatalf("expected %d items, got %d", len(want), len(got))
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("expected %v, got %v", want, got)
		}
	}
}
