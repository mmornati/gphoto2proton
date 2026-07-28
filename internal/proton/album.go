package proton

import (
	"context"
	"errors"
)

type AlbumManager struct{}

func NewAlbumManager() *AlbumManager {
	return &AlbumManager{}
}

func (a *AlbumManager) ListAlbums(ctx context.Context) ([]string, error) {
	return nil, errors.New("not implemented")
}

func (a *AlbumManager) CreateAlbum(ctx context.Context, name string) error {
	return errors.New("not implemented")
}
