package takeout

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

func TestCompilesTakeoutReader(t *testing.T) {
	var _ port.TakeoutReader = (*Reader)(nil)
}

func makeTar(files map[string][]byte) []byte {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		content := files[name]
		hdr := &tar.Header{
			Name: name,
			Size: int64(len(content)),
			Mode: 0644,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			panic(err)
		}
		if _, err := tw.Write(content); err != nil {
			panic(err)
		}
	}
	tw.Close()
	return buf.Bytes()
}

func makeTarGz(files map[string][]byte) []byte {
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gw)
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		content := files[name]
		hdr := &tar.Header{
			Name: name,
			Size: int64(len(content)),
			Mode: 0644,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			panic(err)
		}
		if _, err := tw.Write(content); err != nil {
			panic(err)
		}
	}
	tw.Close()
	gw.Close()
	return buf.Bytes()
}

func writeFile(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestNextReturnsMediaFromTar(t *testing.T) {
	sidecar := map[string]interface{}{
		"title": "IMG_0001.JPG",
		"photoTakenTime": map[string]string{
			"timestamp": "1609459200",
			"formatted": "Jan 1, 2021",
		},
	}
	sidecarJSON, _ := json.Marshal(sidecar)

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":           []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json":      sidecarJSON,
		"Takeout/IMG_0002.JPG":           []byte("fake-jpeg-data-2"),
		"Takeout/IMG_0002.JPG.json":      []byte(`{"title":"IMG_0002.JPG"}`),
		"Takeout/.Trashes/desktop.ini":   []byte("trash"),
		"Takeout/Albums/album-info.json": []byte(`{"title":"Album"}`),
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)

	r := NewStreamReader(tarPath)
	ctx := context.Background()

	media1, rc1, err := r.Next(ctx)
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if media1.Filename != "IMG_0001.JPG" {
		t.Fatalf("expected IMG_0001.JPG, got: %s", media1.Filename)
	}
	data1, _ := io.ReadAll(rc1)
	if string(data1) != "fake-jpeg-data" {
		t.Fatalf("expected fake-jpeg-data, got: %s", string(data1))
	}
	rc1.Close()

	media2, rc2, err := r.Next(ctx)
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if media2.Filename != "IMG_0002.JPG" {
		t.Fatalf("expected IMG_0002.JPG, got: %s", media2.Filename)
	}
	rc2.Close()

	_, _, err = r.Next(ctx)
	if !errors.Is(err, io.EOF) {
		t.Fatalf("expected io.EOF, got: %v", err)
	}
}

func TestNextReturnsEOFForEmptyArchive(t *testing.T) {
	tarData := makeTar(map[string][]byte{
		"Takeout/Albums/list.json": []byte(`[]`),
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "empty.tar", tarData)

	r := NewStreamReader(tarPath)
	ctx := context.Background()

	_, _, err := r.Next(ctx)
	if !errors.Is(err, io.EOF) {
		t.Fatalf("expected io.EOF, got: %v", err)
	}
}

func TestNextReturnsErrorForNonTarFile(t *testing.T) {
	dir := t.TempDir()
	path := writeFile(t, dir, "not-a-tar.bin", []byte("this is not a tar file"))

	r := NewStreamReader(path)
	ctx := context.Background()

	_, _, err := r.Next(ctx)
	if err == nil {
		t.Fatal("expected error for non-tar file, got nil")
	}
}

func TestCorruptTarEntryReturnsError(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{
		Name: "good.txt",
		Size: 5,
		Mode: 0644,
	})
	_, _ = tw.Write([]byte("hello"))

	hdr := &tar.Header{Name: "broken.bin", Size: 10, Mode: 0644}
	_ = tw.WriteHeader(hdr)
	_, _ = tw.Write([]byte("short"))

	_ = tw.WriteHeader(&tar.Header{
		Name: "photo.jpg",
		Size: 4,
		Mode: 0644,
	})
	_, _ = tw.Write([]byte("data"))

	tw.Close()

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "corrupt.tar", buf.Bytes())

	r := NewStreamReader(tarPath)
	ctx := context.Background()

	_, _, err := r.Next(ctx)
	if err == nil || err.Error() != "reading tar part 1: unexpected EOF" {
		t.Fatalf("expected corrupt tar error, got: %v", err)
	}
}

func TestSidecarParsingFullMetadata(t *testing.T) {
	sidecar := map[string]interface{}{
		"title": "IMG_1234.JPG",
		"photoTakenTime": map[string]string{
			"timestamp": "1609459200",
			"formatted": "Jan 1, 2021, 12:00:00 AM UTC",
		},
		"geoData": map[string]interface{}{
			"latitude":  37.7749,
			"longitude": -122.4194,
			"altitude":  16.0,
		},
		"description": "Golden Gate Bridge",
	}
	sidecarJSON, _ := json.Marshal(sidecar)

	meta, err := ParseSidecar(bytes.NewReader(sidecarJSON))
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if meta.DateTimeOriginal != "1609459200" {
		t.Fatalf("expected 1609459200, got: %s", meta.DateTimeOriginal)
	}
	if meta.Latitude != 37.7749 {
		t.Fatalf("expected 37.7749, got: %f", meta.Latitude)
	}
	if meta.Longitude != -122.4194 {
		t.Fatalf("expected -122.4194, got: %f", meta.Longitude)
	}
	if meta.Altitude != 16.0 {
		t.Fatalf("expected 16.0, got: %f", meta.Altitude)
	}
	if meta.Description != "Golden Gate Bridge" {
		t.Fatalf("expected Golden Gate Bridge, got: %s", meta.Description)
	}
}

func TestSidecarParsingEmptyJSON(t *testing.T) {
	meta, err := ParseSidecar(bytes.NewReader([]byte(`{}`)))
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if meta.Description != "" {
		t.Fatalf("expected empty description, got: %s", meta.Description)
	}
}

func TestNextWithGzipTar(t *testing.T) {
	tarData := makeTarGz(map[string][]byte{
		"photo1.jpg": []byte("jpeg-data"),
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tgz", tarData)

	r := NewStreamReader(tarPath)
	ctx := context.Background()

	media, rc, err := r.Next(ctx)
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if media.Filename != "photo1.jpg" {
		t.Fatalf("expected photo1.jpg, got: %s", media.Filename)
	}
	data, _ := io.ReadAll(rc)
	if string(data) != "jpeg-data" {
		t.Fatalf("expected jpeg-data, got: %s", string(data))
	}
	rc.Close()
}

func TestNonMediaEntriesSkipped(t *testing.T) {
	tarData := makeTar(map[string][]byte{
		"Takeout/":                       nil,
		"Takeout/IMG_0001.jpg":           []byte("data"),
		"Takeout/.Trashes/":              nil,
		"Takeout/.Trashes/desktop.ini":   []byte("trash"),
		"Takeout/IMG_0002.jpg":           []byte("data2"),
		"Takeout/Albums/album-info.json": []byte(`{}`),
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)

	r := NewStreamReader(tarPath)
	ctx := context.Background()

	count := 0
	for {
		_, rc, err := r.Next(ctx)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		rc.Close()
		count++
	}
	if count != 2 {
		t.Fatalf("expected 2 media files, got: %d", count)
	}
}

func TestAlbumManifestEmptyForNoAlbums(t *testing.T) {
	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG": []byte("fake-jpeg-data"),
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 0 {
		t.Fatalf("expected 0 albums when no album metadata present, got %d", len(albums))
	}
}

func TestAlbumManifestTopLevelAlbumJSON(t *testing.T) {
	albumData := map[string]interface{}{
		"albumData": map[string]interface{}{
			"title": "Summer 2024",
			"date": map[string]string{
				"timestamp": "1625097600",
				"formatted": "Jul 1, 2021",
			},
			"albumItems": []map[string]string{
				{"title": "IMG_0001.JPG"},
				{"title": "IMG_0002.JPG"},
			},
		},
	}
	albumJSON, _ := json.Marshal(albumData)

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":      []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json": []byte(`{"title":"IMG_0001.JPG"}`),
		"Takeout/IMG_0002.JPG":      []byte("fake-jpeg-data-2"),
		"Takeout/IMG_0002.JPG.json": []byte(`{"title":"IMG_0002.JPG"}`),
		"Takeout/album.json":        albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(albums))
	}
	if albums[0].Name != "Summer 2024" {
		t.Fatalf("expected album name 'Summer 2024', got %q", albums[0].Name)
	}
	if len(albums[0].FileIDs) != 2 {
		t.Fatalf("expected 2 file IDs, got %d", len(albums[0].FileIDs))
	}
	wantIDs := map[string]bool{"IMG_0001.JPG": true, "IMG_0002.JPG": true}
	for _, id := range albums[0].FileIDs {
		if !wantIDs[id] {
			t.Fatalf("unexpected file ID %q in album", id)
		}
	}
}

func TestAlbumManifestPerAlbumJSON(t *testing.T) {
	albumJSON, _ := json.Marshal(map[string]interface{}{
		"title":       "Album Name",
		"description": "Description",
		"coverPhoto":  "IMG_0001.JPG",
		"mediaItems":  []string{"IMG_0001.JPG", "IMG_0002.JPG"},
	})

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":                               []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json":                          []byte(`{"title":"IMG_0001.JPG"}`),
		"Takeout/IMG_0002.JPG":                               []byte("fake-jpeg-data-2"),
		"Takeout/IMG_0002.JPG.json":                          []byte(`{"title":"IMG_0002.JPG"}`),
		"Takeout/Google Photos/Albums/Album Name/album.json": albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(albums))
	}
	if albums[0].Name != "Album Name" {
		t.Fatalf("expected album name 'Album Name', got %q", albums[0].Name)
	}
	if len(albums[0].FileIDs) != 2 {
		t.Fatalf("expected 2 file IDs, got %d", len(albums[0].FileIDs))
	}
}

func TestAlbumManifestPhotoInMultipleAlbums(t *testing.T) {
	albumData := map[string]interface{}{
		"albumData": []map[string]interface{}{
			{
				"title": "Summer 2024",
				"albumItems": []map[string]string{
					{"title": "IMG_0001.JPG"},
				},
			},
			{
				"title": "Vacation",
				"albumItems": []map[string]string{
					{"title": "IMG_0001.JPG"},
					{"title": "IMG_0002.JPG"},
				},
			},
		},
	}
	albumJSON, _ := json.Marshal(albumData)

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":      []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json": []byte(`{"title":"IMG_0001.JPG"}`),
		"Takeout/IMG_0002.JPG":      []byte("fake-jpeg-data-2"),
		"Takeout/IMG_0002.JPG.json": []byte(`{"title":"IMG_0002.JPG"}`),
		"Takeout/album.json":        albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 2 {
		t.Fatalf("expected 2 albums, got %d", len(albums))
	}
	byName := map[string]domain.Album{}
	for _, a := range albums {
		byName[a.Name] = a
	}
	if _, ok := byName["Summer 2024"]; !ok {
		t.Fatal("missing 'Summer 2024' album")
	}
	if _, ok := byName["Vacation"]; !ok {
		t.Fatal("missing 'Vacation' album")
	}
	found := false
	for _, id := range byName["Summer 2024"].FileIDs {
		if id == "IMG_0001.JPG" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("IMG_0001.JPG not in 'Summer 2024' album")
	}
	found = false
	for _, id := range byName["Vacation"].FileIDs {
		if id == "IMG_0001.JPG" {
			found = true
			break
		}
	}
	if !found {
		t.Fatal("IMG_0001.JPG not in 'Vacation' album")
	}
}

func TestAlbumManifestEmptyAlbum(t *testing.T) {
	albumData := map[string]interface{}{
		"albumData": map[string]interface{}{
			"title":      "Empty Album",
			"date":       map[string]string{"timestamp": "1625097600"},
			"albumItems": []map[string]string{},
		},
	}
	albumJSON, _ := json.Marshal(albumData)

	tarData := makeTar(map[string][]byte{
		"Takeout/album.json": albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album (including empty), got %d", len(albums))
	}
	if albums[0].Name != "Empty Album" {
		t.Fatalf("expected album name 'Empty Album', got %q", albums[0].Name)
	}
	if len(albums[0].FileIDs) != 0 {
		t.Fatalf("expected empty file IDs, got %d", len(albums[0].FileIDs))
	}
}

func TestAlbumManifestSpecialCharacters(t *testing.T) {
	albumData := map[string]interface{}{
		"albumData": map[string]interface{}{
			"title": "Vacation 🏖️ 2024",
			"date":  map[string]string{"timestamp": "1625097600"},
			"albumItems": []map[string]string{
				{"title": "IMG_0001.JPG"},
			},
		},
	}
	albumJSON, _ := json.Marshal(albumData)

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":      []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json": []byte(`{"title":"IMG_0001.JPG"}`),
		"Takeout/album.json":        albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(albums))
	}
	if albums[0].Name != "Vacation 🏖️ 2024" {
		t.Fatalf("expected emoji album name preserved, got %q", albums[0].Name)
	}
}

func TestAlbumManifestFromSidecarAlbumData(t *testing.T) {
	sidecar1 := map[string]interface{}{
		"title": "IMG_0001.JPG",
		"albumData": map[string]interface{}{
			"title": "From Sidecar Album",
			"albumItems": []map[string]string{
				{"title": "IMG_0001.JPG"},
			},
		},
	}
	sidecar1JSON, _ := json.Marshal(sidecar1)

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":      []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json": sidecar1JSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(albums))
	}
	if albums[0].Name != "From Sidecar Album" {
		t.Fatalf("expected album name 'From Sidecar Album', got %q", albums[0].Name)
	}
}

func TestAlbumManifestMergesFormats(t *testing.T) {
	albumJSON, _ := json.Marshal(map[string]interface{}{
		"title":      "Album Name",
		"mediaItems": []string{"IMG_0001.JPG"},
	})

	sidecar := map[string]interface{}{
		"title": "IMG_0002.JPG",
		"albumData": map[string]interface{}{
			"title":      "Album Name",
			"albumItems": []map[string]string{{"title": "IMG_0002.JPG"}},
		},
	}
	sidecarJSON, _ := json.Marshal(sidecar)

	tarData := makeTar(map[string][]byte{
		"Takeout/IMG_0001.JPG":                               []byte("fake-jpeg-data"),
		"Takeout/IMG_0001.JPG.json":                          []byte(`{"title":"IMG_0001.JPG"}`),
		"Takeout/IMG_0002.JPG":                               []byte("fake-jpeg-data-2"),
		"Takeout/IMG_0002.JPG.json":                          sidecarJSON,
		"Takeout/Google Photos/Albums/Album Name/album.json": albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 merged album, got %d", len(albums))
	}
	if len(albums[0].FileIDs) != 2 {
		t.Fatalf("expected 2 file IDs after merge, got %d", len(albums[0].FileIDs))
	}
}

func TestAlbumManifestCreatedAtParsed(t *testing.T) {
	albumData := map[string]interface{}{
		"albumData": map[string]interface{}{
			"title": "Dated Album",
			"date": map[string]string{
				"timestamp": "1625097600",
				"formatted": "Jul 1, 2021",
			},
			"albumItems": []map[string]string{
				{"title": "IMG_0001.JPG"},
			},
		},
	}
	albumJSON, _ := json.Marshal(albumData)

	tarData := makeTar(map[string][]byte{
		"Takeout/album.json": albumJSON,
	})

	dir := t.TempDir()
	tarPath := writeFile(t, dir, "test.tar", tarData)
	r := NewStreamReader(tarPath)

	albums, err := r.AlbumManifest(context.Background())
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	if len(albums) != 1 {
		t.Fatalf("expected 1 album, got %d", len(albums))
	}
	if albums[0].CreatedAt.IsZero() {
		t.Fatal("expected CreatedAt to be set, got zero value")
	}
}
