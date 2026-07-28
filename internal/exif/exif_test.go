package exif

import (
	"bytes"
	"context"
	"io"
	"os"
	"testing"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/port"
)

func TestCompilesExifProcessor(t *testing.T) {
	var _ port.ExifProcessor = (*Processor)(nil)
}

func TestNewProcessorExiftoolMissing(t *testing.T) {
	origPath := os.Getenv("PATH")
	os.Setenv("PATH", "")
	defer os.Setenv("PATH", origPath)

	p := NewProcessor().(*Processor)
	if p.available {
		t.Fatal("expected processor to report unavailable")
	}
}

func TestProcessReturnsErrorWhenExiftoolMissing(t *testing.T) {
	origPath := os.Getenv("PATH")
	os.Setenv("PATH", "")
	defer os.Setenv("PATH", origPath)

	p := NewProcessor()
	rc, err := p.Process(context.Background(), bytes.NewReader([]byte("data")), &domain.MediaMeta{
		DateTimeOriginal: "1609459200",
	})
	if err == nil {
		rc.Close()
		t.Fatal("expected error when exiftool missing")
	}
	rc.Close()
}

func TestProcessPassthroughNilMeta(t *testing.T) {
	p := NewProcessor().(*Processor)
	p.available = true
	p.exifPath = "exiftool"

	rc, err := p.Process(context.Background(), bytes.NewReader([]byte("original-data")), nil)
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	data, _ := io.ReadAll(rc)
	if string(data) != "original-data" {
		t.Fatalf("expected original-data, got: %s", string(data))
	}
	rc.Close()
}

func TestProcessPassthroughEmptyArgs(t *testing.T) {
	p := NewProcessor().(*Processor)
	p.available = true
	p.exifPath = "exiftool"

	rc, err := p.Process(context.Background(), bytes.NewReader([]byte("data")), &domain.MediaMeta{})
	if err != nil {
		t.Fatalf("expected nil error, got: %v", err)
	}
	data, _ := io.ReadAll(rc)
	if string(data) != "data" {
		t.Fatalf("expected data, got: %s", string(data))
	}
	rc.Close()
}

func TestEpochToExifValid(t *testing.T) {
	result := epochToExif("1609459200")
	expected := "2021:01:01 00:00:00"
	if result != expected {
		t.Fatalf("expected %s, got: %s", expected, result)
	}
}

func TestEpochToExifZero(t *testing.T) {
	result := epochToExif("0")
	expected := "1970:01:01 00:00:00"
	if result != expected {
		t.Fatalf("expected %s, got: %s", expected, result)
	}
}

func TestEpochToExifEmpty(t *testing.T) {
	result := epochToExif("")
	if result != "" {
		t.Fatalf("expected empty string, got: %s", result)
	}
}

func TestEpochToExifInvalid(t *testing.T) {
	result := epochToExif("not-a-number")
	if result != "" {
		t.Fatalf("expected empty string, got: %s", result)
	}
}

func TestBuildArgsAllFields(t *testing.T) {
	p := &Processor{exifPath: "exiftool", available: true}
	meta := &domain.MediaMeta{
		DateTimeOriginal: "1609459200",
		Latitude:         37.7749,
		Longitude:        -122.4194,
		Altitude:         16.0,
		Description:      "Golden Gate Bridge",
	}
	args := p.buildArgs(meta)
	if len(args) == 0 {
		t.Fatal("expected non-empty args")
	}
	if args[0] != "-overwrite_original" {
		t.Fatalf("expected -overwrite_original, got: %s", args[0])
	}
	hasDateTime := false
	hasGPSLat := false
	hasGPSLong := false
	hasAltitude := false
	hasDesc := false
	for _, a := range args {
		switch {
		case a == "-DateTimeOriginal=2021:01:01 00:00:00":
			hasDateTime = true
		case a == "-GPSLatitude=37.774900":
			hasGPSLat = true
		case a == "-GPSLongitude=-122.419400":
			hasGPSLong = true
		case a == "-GPSAltitude=16.000000":
			hasAltitude = true
		case a == "-ImageDescription=Golden Gate Bridge":
			hasDesc = true
		}
	}
	if !hasDateTime {
		t.Error("missing DateTimeOriginal arg")
	}
	if !hasGPSLat {
		t.Error("missing GPSLatitude arg")
	}
	if !hasGPSLong {
		t.Error("missing GPSLongitude arg")
	}
	if !hasAltitude {
		t.Error("missing GPSAltitude arg")
	}
	if !hasDesc {
		t.Error("missing ImageDescription arg")
	}
}

func TestBuildArgsNoMetadata(t *testing.T) {
	p := &Processor{exifPath: "exiftool", available: true}
	args := p.buildArgs(&domain.MediaMeta{})
	if len(args) != 0 {
		t.Fatalf("expected empty args, got: %v", args)
	}
}

func TestBuildArgsDateTimeOnly(t *testing.T) {
	p := &Processor{exifPath: "exiftool", available: true}
	args := p.buildArgs(&domain.MediaMeta{
		DateTimeOriginal: "1609459200",
	})
	if len(args) != 5 {
		t.Fatalf("expected 5 args, got %d: %v", len(args), args)
	}
}
