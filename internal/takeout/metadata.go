package takeout

import (
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/mmornati/gphoto2proton/internal/domain"
)

var mediaExtensions = map[string]bool{
	".jpg": true, ".jpeg": true, ".png": true, ".gif": true,
	".heic": true, ".mov": true, ".mp4": true,
	".cr2": true, ".nef": true, ".arw": true,
}

func isMediaFile(name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	return mediaExtensions[ext]
}

type googlePhotosSidecar struct {
	Title          string          `json:"title"`
	PhotoTakenTime *timeData       `json:"photoTakenTime"`
	GeoData        *geoData        `json:"geoData"`
	Description    string          `json:"description"`
	AlbumData      json.RawMessage `json:"albumData"`
}

type timeData struct {
	Timestamp string `json:"timestamp"`
	Formatted string `json:"formatted"`
}

type geoData struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
	Altitude  float64 `json:"altitude"`
}

type albumItem struct {
	Title string `json:"title"`
}

type albumDataPayload struct {
	Title      string      `json:"title"`
	Date       *timeData   `json:"date"`
	GeoData    *geoData    `json:"geoData"`
	AlbumItems []albumItem `json:"albumItems"`
	MediaItems []string    `json:"mediaItems"`
}

type perAlbumJSON struct {
	Title       string   `json:"title"`
	Description string   `json:"description"`
	CoverPhoto  string   `json:"coverPhoto"`
	MediaItems  []string `json:"mediaItems"`
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

func ParseSidecarAlbums(r io.Reader) ([]domain.Album, error) {
	var sidecar googlePhotosSidecar
	if err := json.NewDecoder(r).Decode(&sidecar); err != nil {
		return nil, fmt.Errorf("parsing sidecar JSON: %w", err)
	}
	if len(sidecar.AlbumData) == 0 {
		return nil, nil
	}

	payloads, err := decodeAlbumPayloads(sidecar.AlbumData)
	if err != nil {
		return nil, fmt.Errorf("parsing albumData: %w", err)
	}

	out := make([]domain.Album, 0, len(payloads))
	for _, p := range payloads {
		out = append(out, buildAlbumFromPayload(p))
	}
	return out, nil
}

func ParseTopLevelAlbum(r io.Reader) ([]domain.Album, error) {
	var doc struct {
		AlbumData json.RawMessage `json:"albumData"`
	}
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		return nil, fmt.Errorf("parsing top-level album.json: %w", err)
	}
	if len(doc.AlbumData) == 0 {
		return nil, nil
	}
	payloads, err := decodeAlbumPayloads(doc.AlbumData)
	if err != nil {
		return nil, fmt.Errorf("parsing albumData: %w", err)
	}
	out := make([]domain.Album, 0, len(payloads))
	for _, p := range payloads {
		out = append(out, buildAlbumFromPayload(p))
	}
	return out, nil
}

func ParsePerAlbumJSON(r io.Reader) (domain.Album, error) {
	var doc perAlbumJSON
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		return domain.Album{}, fmt.Errorf("parsing per-album JSON: %w", err)
	}
	album := domain.Album{
		Name:    doc.Title,
		FileIDs: append([]string(nil), doc.MediaItems...),
	}
	return album, nil
}

func decodeAlbumPayloads(raw json.RawMessage) ([]albumDataPayload, error) {
	trimmed := bytesTrimSpace(raw)
	if len(trimmed) == 0 {
		return nil, nil
	}
	if trimmed[0] == '[' {
		var list []albumDataPayload
		if err := json.Unmarshal(trimmed, &list); err != nil {
			return nil, err
		}
		return list, nil
	}
	var single albumDataPayload
	if err := json.Unmarshal(trimmed, &single); err != nil {
		return nil, err
	}
	return []albumDataPayload{single}, nil
}

func buildAlbumFromPayload(p albumDataPayload) domain.Album {
	album := domain.Album{
		Name: p.Title,
	}
	if len(p.AlbumItems) > 0 {
		ids := make([]string, 0, len(p.AlbumItems))
		for _, item := range p.AlbumItems {
			if item.Title != "" {
				ids = append(ids, item.Title)
			}
		}
		album.FileIDs = ids
	}
	if len(p.MediaItems) > 0 {
		ids := append([]string(nil), p.MediaItems...)
		album.FileIDs = mergeFileIDs(album.FileIDs, ids)
	}
	if p.Date != nil && p.Date.Timestamp != "" {
		if ts, err := parseUnixTimestamp(p.Date.Timestamp); err == nil {
			album.CreatedAt = ts
		}
	}
	return album
}

func parseUnixTimestamp(s string) (time.Time, error) {
	ts, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("parsing unix timestamp %q: %w", s, err)
	}
	return time.Unix(ts, 0).UTC(), nil
}

func mergeFileIDs(a, b []string) []string {
	if len(a) == 0 {
		return b
	}
	if len(b) == 0 {
		return a
	}
	seen := make(map[string]bool, len(a)+len(b))
	out := make([]string, 0, len(a)+len(b))
	for _, id := range a {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	for _, id := range b {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

func bytesTrimSpace(b []byte) []byte {
	start := 0
	end := len(b)
	for start < end {
		c := b[start]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			break
		}
		start++
	}
	for end > start {
		c := b[end-1]
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			break
		}
		end--
	}
	return b[start:end]
}

func IsTopLevelAlbumFile(path string) bool {
	base := filepath.Base(path)
	if base != "album.json" {
		return false
	}
	dir := filepath.ToSlash(filepath.Dir(path))
	if dir == "." || dir == "" {
		return true
	}
	parts := strings.Split(dir, "/")
	for _, p := range parts {
		if strings.EqualFold(p, "Albums") {
			return false
		}
	}
	return true
}

func IsPerAlbumFile(path string) bool {
	base := filepath.Base(path)
	if base != "album.json" {
		return false
	}
	dir := filepath.ToSlash(filepath.Dir(path))
	if dir == "." || dir == "" {
		return false
	}
	parts := strings.Split(dir, "/")
	for _, p := range parts {
		if strings.EqualFold(p, "Albums") {
			return true
		}
	}
	return false
}

func IsPhotoSidecar(path string) bool {
	base := filepath.Base(path)
	if base == "album.json" {
		return false
	}
	if !strings.HasSuffix(base, ".json") {
		return false
	}
	stripped := strings.TrimSuffix(base, ".json")
	if !isMediaFile(stripped) {
		return false
	}
	dir := filepath.ToSlash(filepath.Dir(path))
	if dir == "." || dir == "" {
		return true
	}
	parts := strings.Split(dir, "/")
	for _, p := range parts {
		if strings.EqualFold(p, "Albums") {
			return false
		}
	}
	return true
}
