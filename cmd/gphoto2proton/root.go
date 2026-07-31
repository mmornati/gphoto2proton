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
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/mmornati/gphoto2proton/internal/domain"
	"github.com/mmornati/gphoto2proton/internal/exif"
	"github.com/mmornati/gphoto2proton/internal/port"
	"github.com/mmornati/gphoto2proton/internal/proton"
	"github.com/mmornati/gphoto2proton/internal/state"
	"github.com/mmornati/gphoto2proton/internal/takeout"
)

var Version = "dev"

var rootCmd *cobra.Command

func init() {
	rootCmd = newRootCmd()
}

func newRootCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "gphoto2proton",
		Short: "Migrate Google Photos Takeout archives to Proton Drive",
		Long: `A single-command CLI tool to migrate Google Photos Takeout archives
to Proton Drive with streaming, EXIF restoration, album recreation, and resume safety.`,
	}

	homeDir, err := os.UserHomeDir()
	if err != nil {
		homeDir = "~"
	}
	defaultStateDir := filepath.Join(homeDir, ".gphoto2proton", "state")

	sync := &cobra.Command{
		Use:   "sync",
		Short: "Run the migration pipeline against a Takeout archive",
		Long:  `Process a Google Takeout archive and upload photos to Proton Drive.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			takeoutDir, _ := cmd.Flags().GetString("takeout-dir")
			takeoutArchive, _ := cmd.Flags().GetString("takeout-archive")
			if takeoutDir == "" && takeoutArchive == "" {
				return fmt.Errorf("required flag(s) \"takeout-dir\" or \"takeout-archive\" not set")
			}
			if takeoutDir != "" && takeoutArchive != "" {
				return errors.New("--takeout-dir and --takeout-archive are mutually exclusive")
			}
			resume, _ := cmd.Flags().GetBool("resume")
			stateDir, _ := cmd.Flags().GetString("state-dir")
			deleteAfter, _ := cmd.Flags().GetBool("delete-after")

			stateDBPath := filepath.Join(stateDir, "state.db")
			tracker, err := state.NewSQLiteTracker(stateDBPath)
			if err != nil {
				return fmt.Errorf("opening state database: %w", err)
			}
			defer tracker.Close()

			var reader port.TakeoutReader
			if takeoutArchive != "" {
				reader = takeout.NewStreamReader(takeoutArchive)
			} else {
				dr, err := takeout.NewDirReader(takeoutDir)
				if err != nil {
					return fmt.Errorf("reading takeout directory: %w", err)
				}
				reader = dr
			}

			exifProcessor := exif.NewProcessor()

			username, _ := cmd.Flags().GetString("username")
			password, _ := cmd.Flags().GetString("password")
			twoFA, _ := cmd.Flags().GetString("twofa")
			var uploader port.ProtonUploader
			if username != "" && password != "" {
				credStore := proton.NewCredentialStore(stateDir)
				up, err := proton.NewUploader(cmd.Context(), username, password, twoFA, credStore)
				if err != nil {
					return fmt.Errorf("creating uploader: %w", err)
				}
				uploader = up
			} else {
				slog.Warn("--username/--password not set, upload disabled")
			}

			p := &Pipeline{
				Reader:   reader,
				Uploader: uploader,
				State:    tracker,
				Exif:     exifProcessor,
				Logger:   slog.Default(),
				Resume:   resume,
			}

			if err := p.Run(cmd.Context()); err != nil {
				return fmt.Errorf("pipeline run failed: %w", err)
			}

			if deleteAfter && takeoutArchive != "" {
				if err := os.Remove(takeoutArchive); err != nil {
					return fmt.Errorf("deleting archive: %w", err)
				}
			}

			return nil
		},
	}
	sync.Flags().String("takeout-dir", "", "Path to extracted Google Takeout directory")
	sync.Flags().String("takeout-archive", "", "Path to a single Google Takeout .tgz archive")
	sync.Flags().Bool("delete-after", false, "Delete the archive file after successful processing")
	sync.Flags().Bool("resume", false, "Skip completed files and retry failed ones")
	sync.Flags().String("state-dir", defaultStateDir, "Directory for SQLite state database")
	sync.Flags().Bool("album-recreate", false, "Recreate albums in Proton Drive (no-op until Epic 2)")
	sync.Flags().String("username", "", "Proton account username (email)")
	sync.Flags().String("password", "", "Proton account password")
	sync.Flags().String("twofa", "", "Proton account TOTP 2FA code (only needed on first login)")

	albumsFinalize := &cobra.Command{
		Use:   "albums-finalize",
		Short: "Create albums in Proton Photos from accumulated membership data",
		Long: `Read accumulated album membership from the SQLite state database
and create albums in Proton Photos for all uploaded files.
This should be run after all archives have been processed.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			stateDir, _ := cmd.Flags().GetString("state-dir")
			username, _ := cmd.Flags().GetString("username")
			password, _ := cmd.Flags().GetString("password")
			twoFA, _ := cmd.Flags().GetString("twofa")

			if username == "" || password == "" {
				return fmt.Errorf("--username and --password are required for albums-finalize")
			}

			dbPath := filepath.Join(stateDir, "state.db")
			tracker, err := state.NewSQLiteTracker(dbPath)
			if err != nil {
				return fmt.Errorf("opening state database: %w", err)
			}
			defer tracker.Close()

			albums, err := tracker.AccumulatedAlbums(cmd.Context())
			if err != nil {
				return fmt.Errorf("reading accumulated albums: %w", err)
			}

			if len(albums) == 0 {
				fmt.Fprintf(os.Stderr, "no accumulated albums found in state database\n")
				return nil
			}

			fileStates, err := tracker.FileStates(cmd.Context(), "")
			if err != nil {
				return fmt.Errorf("reading file states: %w", err)
			}

			fileNameToFileID := make(map[string]string, len(fileStates))
			for _, fs := range fileStates {
				if fs.FileName != "" && fs.FileID != "" {
					fileNameToFileID[fs.FileName] = fs.FileID
				}
			}

			credStore := proton.NewCredentialStore(stateDir)
			uploader, err := proton.NewUploader(cmd.Context(), username, password, twoFA, credStore)
			if err != nil {
				return fmt.Errorf("creating uploader: %w", err)
			}

			for _, album := range albums {
				protonFileIDs := make([]string, 0, len(album.FileIDs))
				for _, fn := range album.FileIDs {
					if id, ok := fileNameToFileID[fn]; ok {
						protonFileIDs = append(protonFileIDs, id)
					}
				}
				if len(protonFileIDs) == 0 {
					fmt.Fprintf(os.Stderr, "skipping album %q: no matching Proton file IDs\n", album.Name)
					continue
				}

				albumID, err := uploader.CreateAlbum(cmd.Context(), album.Name, protonFileIDs)
				if err != nil {
					fmt.Fprintf(os.Stderr, "failed to create album %q: %v\n", album.Name, err)
					continue
				}

				if err := tracker.RecordAlbum(cmd.Context(), albumID, domain.StateAlbumAttached); err != nil {
					fmt.Fprintf(os.Stderr, "warning: failed to record album state for %q: %v\n", album.Name, err)
				}

				fmt.Fprintf(os.Stderr, "created album %q (id=%s) with %d photos\n", album.Name, albumID, len(protonFileIDs))
			}
			return nil
		},
	}
	albumsFinalize.Flags().String("state-dir", defaultStateDir, "Directory for SQLite state database")
	albumsFinalize.Flags().String("username", "", "Proton account username (email)")
	albumsFinalize.Flags().String("password", "", "Proton account password")
	albumsFinalize.Flags().String("twofa", "", "Proton account TOTP 2FA code (only needed on first login)")

	version := &cobra.Command{
		Use:   "version",
		Short: "Print the version number",
		Run: func(cmd *cobra.Command, args []string) {
			cmd.Println(Version)
		},
	}

	root.AddCommand(sync)
	root.AddCommand(albumsFinalize)
	root.AddCommand(version)
	return root
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
