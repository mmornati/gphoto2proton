package takeout

import (
	"bytes"
	"context"
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

type DirReader struct {
	mu        sync.Mutex
	files     []dirMediaFile
	current   int
	albums    []domain.Album
	albumIdx  map[string]*dirAlbumAcc
	albumOrd  []string
	metaCache map[string]*domain.MediaMeta
}

type dirMediaFile struct {
	path string
	name string
}

type dirAlbumAcc struct {
	Name    string
	FileIDs []string
	seen    map[string]bool
}

func NewDirReader(dir string) (*DirReader, error) {
	dr := &DirReader{
		metaCache: make(map[string]*domain.MediaMeta),
		albumIdx:  make(map[string]*dirAlbumAcc),
	}

	if _, statErr := os.Stat(dir); statErr != nil {
		return dr, nil
	}

	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}

		rel, err := filepath.Rel(dir, path)
		if err != nil {
			rel = filepath.Base(path)
		}
		rel = filepath.ToSlash(rel)
		base := filepath.Base(path)

		if IsPhotoSidecar(rel) {
			data, readErr := os.ReadFile(path) // #nosec G122
			if readErr != nil {
				return nil
			}
			mediaName := strings.TrimSuffix(base, ".json")
			meta, metaErr := ParseSidecar(bytes.NewReader(data))
			if metaErr == nil && meta != nil {
				dr.metaCache[mediaName] = meta
			}
			sidecarAlbums, albumErr := ParseSidecarAlbums(bytes.NewReader(data))
			if albumErr == nil {
				dr.mergeDirAlbums(sidecarAlbums)
			}
			return nil
		}

		if IsTopLevelAlbumFile(rel) {
			data, readErr := os.ReadFile(path) // #nosec G122
			if readErr != nil {
				return nil
			}
			albums, parseErr := ParseTopLevelAlbum(bytes.NewReader(data))
			if parseErr == nil {
				dr.mergeDirAlbums(albums)
			}
			return nil
		}

		if IsPerAlbumFile(rel) {
			data, readErr := os.ReadFile(path) // #nosec G122
			if readErr != nil {
				return nil
			}
			album, parseErr := ParsePerAlbumJSON(bytes.NewReader(data))
			if parseErr == nil {
				dr.mergeDirAlbums([]domain.Album{album})
			}
			return nil
		}

		if isMediaFile(base) {
			dr.files = append(dr.files, dirMediaFile{path: path, name: base})
		}

		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walking takeout directory %s: %w", dir, err)
	}

	sort.Slice(dr.files, func(i, j int) bool {
		return dr.files[i].name < dr.files[j].name
	})

	for _, name := range dr.albumOrd {
		acc := dr.albumIdx[name]
		dr.albums = append(dr.albums, domain.Album{
			Name:    acc.Name,
			FileIDs: append([]string(nil), acc.FileIDs...),
		})
	}

	return dr, nil
}

func (d *DirReader) mergeDirAlbums(albums []domain.Album) {
	for _, a := range albums {
		key := a.Name
		if key == "" {
			continue
		}
		acc, exists := d.albumIdx[key]
		if !exists {
			acc = &dirAlbumAcc{
				Name: a.Name,
				seen: make(map[string]bool),
			}
			d.albumIdx[key] = acc
			d.albumOrd = append(d.albumOrd, key)
		}
		for _, id := range a.FileIDs {
			if id == "" || acc.seen[id] {
				continue
			}
			acc.seen[id] = true
			acc.FileIDs = append(acc.FileIDs, id)
		}
	}
}

func (d *DirReader) Next(ctx context.Context) (*domain.Media, io.ReadCloser, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	select {
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	default:
	}

	if d.current >= len(d.files) {
		return nil, nil, io.EOF
	}

	f := d.files[d.current]
	d.current++

	fh, err := os.Open(f.path)
	if err != nil {
		return nil, nil, fmt.Errorf("opening %s: %w", f.path, err)
	}

	data, err := io.ReadAll(fh)
	fh.Close()
	if err != nil {
		return nil, nil, fmt.Errorf("reading %s: %w", f.path, err)
	}

	media := &domain.Media{
		Filename: f.name,
	}
	if meta, ok := d.metaCache[f.name]; ok {
		media.Metadata = meta
	}

	return media, io.NopCloser(bytes.NewReader(data)), nil
}

func (d *DirReader) AlbumManifest(ctx context.Context) ([]domain.Album, error) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	out := make([]domain.Album, len(d.albums))
	copy(out, d.albums)
	return out, nil
}

var _ port.TakeoutReader = (*DirReader)(nil)
