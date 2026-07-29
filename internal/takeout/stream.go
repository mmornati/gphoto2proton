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
	"time"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

type Reader struct {
	readers []*tar.Reader
	files   []io.Closer
	current int
	mu      sync.Mutex
	initErr error

	albumIndex      map[string]albumAccumulator
	albumIndexOrder []string
	sidecarMeta     map[string]*domain.MediaMeta
}

type albumAccumulator struct {
	Name       string
	CreatedAt  time.Time
	HasCreated bool
	FileIDs    []string
	seen       map[string]bool
}

func NewStreamReader(paths ...string) port.TakeoutReader {
	r := &Reader{
		sidecarMeta: make(map[string]*domain.MediaMeta),
	}
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

	for r.current < len(r.readers) {
		hd, err := r.readers[r.current].Next()
		if errors.Is(err, io.EOF) {
			r.current++
			if r.current >= len(r.readers) {
				r.closeFiles()
			}
			continue
		}
		if err != nil {
			return nil, nil, fmt.Errorf("reading tar part %d: %w", r.current+1, err)
		}
		if hd.Typeflag != tar.TypeReg {
			continue
		}
		name := filepath.Base(hd.Name)

		if isMediaFile(name) {
			var buf bytes.Buffer
			if _, err := io.Copy(&buf, r.readers[r.current]); err != nil {
				return nil, nil, fmt.Errorf("reading %s: %w", hd.Name, err)
			}
			media := &domain.Media{
				Filename: name,
			}
			if meta, ok := r.sidecarMeta[name]; ok {
				media.Metadata = meta
				delete(r.sidecarMeta, name)
			}
			return media, io.NopCloser(&buf), nil
		}

		if IsTopLevelAlbumFile(hd.Name) {
			data, err := io.ReadAll(r.readers[r.current])
			if err != nil {
				return nil, nil, fmt.Errorf("reading %s: %w", hd.Name, err)
			}
			albums, err := ParseTopLevelAlbum(bytes.NewReader(data))
			if err != nil {
				return nil, nil, fmt.Errorf("parsing top-level album %s: %w", hd.Name, err)
			}
			r.mergeAlbums(albums)
			continue
		}
		if IsPerAlbumFile(hd.Name) {
			data, err := io.ReadAll(r.readers[r.current])
			if err != nil {
				return nil, nil, fmt.Errorf("reading %s: %w", hd.Name, err)
			}
			album, err := ParsePerAlbumJSON(bytes.NewReader(data))
			if err != nil {
				return nil, nil, fmt.Errorf("parsing per-album JSON %s: %w", hd.Name, err)
			}
			r.mergeAlbums([]domain.Album{album})
			continue
		}
		if IsPhotoSidecar(hd.Name) {
			data, err := io.ReadAll(r.readers[r.current])
			if err != nil {
				return nil, nil, fmt.Errorf("reading sidecar %s: %w", hd.Name, err)
			}
			mediaName := strings.TrimSuffix(name, ".json")
			meta, metaErr := ParseSidecar(bytes.NewReader(data))
			if metaErr == nil && meta != nil {
				r.sidecarMeta[mediaName] = meta
			}
			albums, err := ParseSidecarAlbums(bytes.NewReader(data))
			if err != nil {
				return nil, nil, fmt.Errorf("parsing sidecar albums %s: %w", hd.Name, err)
			}
			r.mergeAlbums(albums)
			continue
		}
	}

	r.closeFiles()
	return nil, nil, io.EOF
}

func (r *Reader) closeFiles() {
	for _, c := range r.files {
		c.Close()
	}
	r.files = nil
}

func (r *Reader) mergeAlbums(albums []domain.Album) {
	if r.albumIndex == nil {
		r.albumIndex = make(map[string]albumAccumulator)
	}
	for _, a := range albums {
		key := a.Name
		if key == "" {
			continue
		}
		acc, exists := r.albumIndex[key]
		if !exists {
			acc = albumAccumulator{
				Name: a.Name,
				seen: make(map[string]bool),
			}
			r.albumIndexOrder = append(r.albumIndexOrder, key)
		}
		for _, id := range a.FileIDs {
			if id == "" || acc.seen[id] {
				continue
			}
			acc.seen[id] = true
			acc.FileIDs = append(acc.FileIDs, id)
		}
		if !acc.HasCreated && !a.CreatedAt.IsZero() {
			acc.CreatedAt = a.CreatedAt
			acc.HasCreated = true
		}
		r.albumIndex[key] = acc
	}
}

func (r *Reader) AlbumManifest(ctx context.Context) ([]domain.Album, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	if r.initErr != nil {
		return nil, r.initErr
	}

	out := make([]domain.Album, 0, len(r.albumIndexOrder))
	for _, key := range r.albumIndexOrder {
		acc, ok := r.albumIndex[key]
		if !ok {
			continue
		}
		album := domain.Album{
			Name:    acc.Name,
			FileIDs: append([]string(nil), acc.FileIDs...),
		}
		if acc.HasCreated {
			album.CreatedAt = acc.CreatedAt
		}
		out = append(out, album)
	}
	return out, nil
}
