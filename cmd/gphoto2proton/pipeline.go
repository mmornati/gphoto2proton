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
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

type Pipeline struct {
	Reader   port.TakeoutReader
	Uploader port.ProtonUploader
	State    port.StateTracker
	OnAlbums domain.AlbumHandler
	Logger   *slog.Logger

	fileIDMap map[string]string
}

func (p *Pipeline) Run(ctx context.Context) error {
	if p.Reader == nil {
		return errors.New("pipeline: reader is required")
	}

	p.fileIDMap = make(map[string]string)

	if err := p.uploadAll(ctx); err != nil {
		return err
	}

	albums, err := p.Reader.AlbumManifest(ctx)
	if err != nil {
		return fmt.Errorf("pipeline: extracting album manifest: %w", err)
	}

	if err := p.recordAlbumMembership(ctx, albums); err != nil {
		return err
	}

	return p.createAlbums(ctx, albums)
}

func (p *Pipeline) recordAlbumMembership(ctx context.Context, albums []domain.Album) error {
	if p.State == nil {
		return nil
	}
	for _, album := range albums {
		for _, fileName := range album.FileIDs {
			if err := p.State.RecordAlbumMembership(ctx, album.Name, fileName); err != nil {
				p.logger().Warn("recording album membership failed",
					slog.String("album", album.Name),
					slog.String("file", fileName),
					slog.String("error", err.Error()),
				)
			}
		}
	}
	return nil
}

func (p *Pipeline) uploadAll(ctx context.Context) error {
	for {
		media, rc, err := p.Reader.Next(ctx)
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("pipeline: reading next media: %w", err)
		}
		if err := p.processMedia(ctx, media, rc); err != nil {
			return err
		}
	}
}

func (p *Pipeline) processMedia(ctx context.Context, media *domain.Media, rc io.ReadCloser) error {
	if media == nil {
		return errors.New("pipeline: reader returned nil media")
	}
	if rc == nil {
		return fmt.Errorf("pipeline: reader returned nil stream for %s", media.Filename)
	}
	defer rc.Close()

	if p.Uploader == nil {
		return nil
	}
	fileID, err := p.Uploader.Upload(ctx, media.Filename, rc)
	if err != nil {
		return fmt.Errorf("pipeline: uploading %s: %w", media.Filename, err)
	}
	if fileID != "" {
		p.fileIDMap[media.Filename] = fileID
	}
	return nil
}

func (p *Pipeline) createAlbums(ctx context.Context, albums []domain.Album) error {
	if p.OnAlbums != nil {
		return p.OnAlbums(ctx, albums)
	}
	if p.Uploader == nil {
		return nil
	}

	for _, album := range albums {
		protonFileIDs := p.translateFileIDs(album.FileIDs)
		if len(protonFileIDs) == 0 {
			p.logger().Warn("skipping album with no Proton file IDs",
				slog.String("album", album.Name),
				slog.Int("takeout_file_ids", len(album.FileIDs)),
			)
			continue
		}

		albumID, err := p.Uploader.CreateAlbum(ctx, album.Name, protonFileIDs)
		if err != nil {
			p.logger().Error("album creation failed",
				slog.String("album", album.Name),
				slog.String("error", err.Error()),
			)
			continue
		}

		if p.State != nil {
			if err := p.State.RecordAlbum(ctx, albumID, domain.StateAlbumAttached); err != nil {
				p.logger().Warn("recording album state failed",
					slog.String("album", album.Name),
					slog.String("album_id", albumID),
					slog.String("error", err.Error()),
				)
			}
		}
	}
	return nil
}

func (p *Pipeline) translateFileIDs(takeoutIDs []string) []string {
	if len(takeoutIDs) == 0 {
		return nil
	}
	out := make([]string, 0, len(takeoutIDs))
	seen := make(map[string]bool, len(takeoutIDs))
	for _, takeoutID := range takeoutIDs {
		if takeoutID == "" || seen[takeoutID] {
			continue
		}
		seen[takeoutID] = true
		protonID, ok := p.fileIDMap[takeoutID]
		if !ok {
			continue
		}
		out = append(out, protonID)
	}
	return out
}

func (p *Pipeline) logger() *slog.Logger {
	if p.Logger != nil {
		return p.Logger
	}
	return slog.Default()
}
