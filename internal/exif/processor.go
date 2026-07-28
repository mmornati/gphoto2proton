package exif

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

type Processor struct {
	exifPath string
	available bool
}

func NewProcessor() port.ExifProcessor {
	path, err := exec.LookPath("exiftool")
	if err != nil {
		slog.Warn("exiftool not found, EXIF processing disabled",
			"error", err,
		)
		return &Processor{available: false}
	}
	slog.Debug("exiftool found", "path", path)
	return &Processor{exifPath: path, available: true}
}

func (p *Processor) Process(ctx context.Context, r io.Reader, meta *domain.MediaMeta) (io.ReadCloser, error) {
	input, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("reading input: %w", err)
	}

	if !p.available {
		return io.NopCloser(bytes.NewReader(input)), fmt.Errorf("exiftool not installed")
	}

	if meta == nil {
		return io.NopCloser(bytes.NewReader(input)), nil
	}

	args := p.buildArgs(meta)
	if len(args) == 0 {
		return io.NopCloser(bytes.NewReader(input)), nil
	}

	output, err := p.runExiftool(ctx, input, args)
	if err != nil {
		slog.Warn("exif: processing failed, returning unmodified stream",
			"error", err,
		)
		return io.NopCloser(bytes.NewReader(input)), nil
	}

	return io.NopCloser(bytes.NewReader(output)), nil
}

func (p *Processor) runExiftool(ctx context.Context, input []byte, args []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, p.exifPath, args...)
	cmd.Stdin = bytes.NewReader(input)

	stdout := new(bytes.Buffer)
	stderr := new(bytes.Buffer)
	cmd.Stdout = stdout
	cmd.Stderr = stderr

	if err := cmd.Run(); err != nil {
		stderrStr := strings.TrimSpace(stderr.String())
		if stderrStr != "" {
			slog.Debug("exif: exiftool stderr", "output", stderrStr)
		}
		return nil, fmt.Errorf("exiftool: %w: %s", err, stderrStr)
	}

	return stdout.Bytes(), nil
}

func (p *Processor) buildArgs(meta *domain.MediaMeta) []string {
	args := []string{"-overwrite_original", "-q", "-"}

	if meta.DateTimeOriginal != "" {
		ts := epochToExif(meta.DateTimeOriginal)
		if ts != "" {
			args = append(args, "-DateTimeOriginal="+ts)
			args = append(args, "-CreateDate="+ts)
		}
	}

	if meta.Latitude != 0 || meta.Longitude != 0 {
		args = append(args, fmt.Sprintf("-GPSLatitude=%f", meta.Latitude))
		args = append(args, fmt.Sprintf("-GPSLongitude=%f", meta.Longitude))
	}

	if meta.Altitude != 0 {
		args = append(args, fmt.Sprintf("-GPSAltitude=%f", meta.Altitude))
	}

	if meta.Description != "" {
		args = append(args, "-ImageDescription="+meta.Description)
	}

	if len(args) == 3 {
		return nil
	}

	return args
}

func epochToExif(epoch string) string {
	ts, err := strconv.ParseInt(epoch, 10, 64)
	if err != nil {
		return ""
	}
	t := time.Unix(ts, 0).UTC()
	return t.Format("2006:01:02 15:04:05")
}
