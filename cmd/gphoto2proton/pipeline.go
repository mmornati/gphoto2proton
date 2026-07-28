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

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

type Pipeline struct {
	Reader   port.TakeoutReader
	Uploader port.ProtonUploader
	OnAlbums domain.AlbumHandler
}

func (p *Pipeline) Run(ctx context.Context) error {
	if p.Reader == nil {
		return errors.New("pipeline: reader is required")
	}

	for {
		media, rc, err := p.Reader.Next(ctx)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("pipeline: reading next media: %w", err)
		}
		if err := p.processMedia(ctx, media, rc); err != nil {
			return err
		}
	}

	albums, err := p.Reader.AlbumManifest(ctx)
	if err != nil {
		return fmt.Errorf("pipeline: extracting album manifest: %w", err)
	}

	if p.OnAlbums != nil {
		if err := p.OnAlbums(ctx, albums); err != nil {
			return fmt.Errorf("pipeline: handling albums: %w", err)
		}
	}

	return nil
}

func (p *Pipeline) processMedia(ctx context.Context, media *domain.Media, rc io.ReadCloser) error {
	if media == nil {
		return errors.New("pipeline: reader returned nil media")
	}
	if rc == nil {
		return fmt.Errorf("pipeline: reader returned nil stream for %s", media.Filename)
	}
	defer rc.Close()

	if p.Uploader != nil {
		if _, err := p.Uploader.Upload(ctx, media.Filename, rc); err != nil {
			return fmt.Errorf("pipeline: uploading %s: %w", media.Filename, err)
		}
	}
	return nil
}
