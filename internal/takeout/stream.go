package takeout

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

var mediaExtensions = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true,
	".heic": true, ".mov": true, ".mp4": true,
	".cr2": true, ".nef": true, ".arw": true,
}

type mediaEntry struct {
	Name        string
	MediaPath   string
	SidecarPath string
	Data        []byte
}

type Reader struct {
	readers []*tar.Reader
	files   []io.Closer
	current int
	entries []mediaEntry
	cursor  int
	mu      sync.Mutex
	initErr error
}

func NewStreamReader(paths ...string) port.TakeoutReader {
	r := &Reader{}
	if len(paths) == 0 {
		return r
	}
	expanded := expandMultiPart(paths)
	for _, p := range expanded {
		if err := r.openArchive(p); err != nil {
			r.initErr = err
			return r
		}
	}
	r.initErr = r.scanAll()
	return r
}

func expandMultiPart(paths []string) []string {
	if len(paths) == 0 {
		return nil
	}
	dir := filepath.Dir(paths[0])
	base := filepath.Base(paths[0])
	base = strings.TrimSuffix(base, filepath.Ext(base))
	entries, err := os.ReadDir(dir)
	if err != nil {
		return paths
	}
	matched := make([]string, 0)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), base) {
			matched = append(matched, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(matched)
	return matched
}

func (r *Reader) openArchive(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("opening %s: %w", path, err)
	}
	if isGzip(path) {
		gr, err := gzip.NewReader(bufio.NewReader(f))
		if err != nil {
			f.Close()
			return fmt.Errorf("decompressing %s: %w", path, err)
		}
		r.readers = append(r.readers, tar.NewReader(gr))
		r.files = append(r.files, gr, f)
	} else {
		r.readers = append(r.readers, tar.NewReader(bufio.NewReader(f)))
		r.files = append(r.files, f)
	}
	return nil
}

func isGzip(path string) bool {
	return strings.HasSuffix(path, ".tgz") || strings.HasSuffix(path, ".tar.gz")
}

func (r *Reader) scanAll() error {
	for r.current < len(r.readers) {
		for {
			hd, err := r.readers[r.current].Next()
			if errors.Is(err, io.EOF) {
				r.current++
				break
			}
			if err != nil {
				return fmt.Errorf("reading tar part %d: %w", r.current+1, err)
			}
			if hd.Typeflag != tar.TypeReg {
				continue
			}
			name := filepath.Base(hd.Name)
			if !isMediaFile(name) {
				continue
			}
			var buf bytes.Buffer
			if _, err := io.Copy(&buf, r.readers[r.current]); err != nil {
				return fmt.Errorf("reading %s: %w", hd.Name, err)
			}
			sidecarPath := hd.Name + ".json"
			r.entries = append(r.entries, mediaEntry{
				Name:        name,
				MediaPath:   hd.Name,
				SidecarPath: sidecarPath,
				Data:        buf.Bytes(),
			})
		}
	}
	r.current = 0
	for _, c := range r.files {
		c.Close()
	}
	r.files = nil
	return nil
}

func (r *Reader) Next(ctx context.Context) (*domain.Media, io.ReadCloser, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if r.initErr != nil {
		return nil, nil, r.initErr
	}

	select {
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	default:
	}

	if r.cursor >= len(r.entries) {
		return nil, nil, io.EOF
	}

	entry := r.entries[r.cursor]
	r.cursor++

	media := &domain.Media{
		Filename: entry.Name,
	}

	return media, io.NopCloser(bytes.NewReader(entry.Data)), nil
}

func (r *Reader) AlbumManifest(ctx context.Context) ([]domain.Album, error) {
	return nil, errors.New("not implemented")
}

func isMediaFile(name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	return mediaExtensions[ext]
}
