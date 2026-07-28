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
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
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
			if takeoutDir == "" {
				return fmt.Errorf("required flag(s) \"takeout-dir\" not set")
			}
			albumRecreate, _ := cmd.Flags().GetBool("album-recreate")
			resume, _ := cmd.Flags().GetBool("resume")
			stateDir, _ := cmd.Flags().GetString("state-dir")

			fmt.Fprintf(os.Stderr, "sync called with takeout-dir=%s album-recreate=%v resume=%v state-dir=%s (not yet implemented)\n",
				takeoutDir, albumRecreate, resume, stateDir)
			return nil
		},
	}
	sync.Flags().String("takeout-dir", "", "Path to extracted Google Takeout directory")
	sync.Flags().Bool("album-recreate", false, "Recreate albums in Proton Drive (no-op until Epic 2)")
	sync.Flags().Bool("resume", false, "Skip completed files and retry failed ones")
	sync.Flags().String("state-dir", defaultStateDir, "Directory for SQLite state database")

	version := &cobra.Command{
		Use:   "version",
		Short: "Print the version number",
		Run: func(cmd *cobra.Command, args []string) {
			cmd.Println(Version)
		},
	}

	root.AddCommand(sync)
	root.AddCommand(version)
	return root
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}
