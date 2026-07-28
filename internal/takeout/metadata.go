package takeout

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/mmornati/gphoto2proton/internal/domain"
)

type googlePhotosSidecar struct {
	Title            string `json:"title"`
	PhotoTakenTime   *timeData `json:"photoTakenTime"`
	GeoData          *geoData  `json:"geoData"`
	Description      string `json:"description"`
}

type timeData struct {
	Timestamp string `json:"timestamp"`
}

type geoData struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Altitude  float64 `json:"altitude"`
}

func ParseSidecar(r io.Reader) (*domain.MediaMeta, error) {
	var raw json.RawMessage
	dec := json.NewDecoder(r)
	if err := dec.Decode(&raw); err != nil {
		return nil, fmt.Errorf("decoding sidecar JSON: %w", err)
	}

	var sidecar googlePhotosSidecar
	if err := json.Unmarshal(raw, &sidecar); err != nil {
		return nil, fmt.Errorf("parsing sidecar JSON: %w", err)
	}

	meta := &domain.MediaMeta{}

	if sidecar.PhotoTakenTime != nil {
		meta.DateTimeOriginal = sidecar.PhotoTakenTime.Timestamp
	}
	if sidecar.GeoData != nil {
		meta.Latitude = sidecar.GeoData.Latitude
		meta.Longitude = sidecar.GeoData.Longitude
		meta.Altitude = sidecar.GeoData.Altitude
	}
	meta.Description = sidecar.Description

	return meta, nil
}
