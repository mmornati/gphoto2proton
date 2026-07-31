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
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spf13/cobra"
)

func testExecute(cmd *cobra.Command, args ...string) (string, error) {
	buf := new(bytes.Buffer)
	cmd.SetOut(buf)
	cmd.SetErr(buf)
	cmd.SetArgs(args)
	_, err := cmd.ExecuteC()
	return buf.String(), err
}

func TestRootHelp(t *testing.T) {
	root := newRootCmd()
	output, err := testExecute(root, "sync", "--help")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, flag := range []string{"--takeout-dir", "--takeout-archive", "--delete-after", "--album-recreate", "--resume", "--state-dir"} {
		if !strings.Contains(output, flag) {
			t.Errorf("expected flag %q in help output", flag)
		}
	}
}

func TestSyncMissingFlag(t *testing.T) {
	root := newRootCmd()
	_, err := testExecute(root, "sync")
	if err == nil {
		t.Fatal("expected error for missing flags")
	}
	if !strings.Contains(err.Error(), "takeout-dir") && !strings.Contains(err.Error(), "takeout-archive") {
		t.Errorf("expected error mentioning takeout-dir or takeout-archive, got: %v", err)
	}
}

func TestVersionOutput(t *testing.T) {
	root := newRootCmd()
	output, err := testExecute(root, "version")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	output = strings.TrimSpace(output)
	if output != Version {
		t.Errorf("expected version %q, got %q", Version, output)
	}
}

func TestSyncWithTakeoutDirSucceeds(t *testing.T) {
	stateDir := t.TempDir()
	root := newRootCmd()
	_, err := testExecute(root, "sync", "--takeout-dir", "/tmp/test-takeout", "--state-dir", stateDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestStateDirDefault(t *testing.T) {
	root := newRootCmd()
	output, err := testExecute(root, "sync", "--help")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, "--state-dir") {
		t.Errorf("expected --state-dir flag in help output")
	}
	if !strings.Contains(output, ".gphoto2proton/state") {
		t.Errorf("expected state-dir default path in help output, got: %s", output)
	}
}

func TestSyncWithTakeoutArchive(t *testing.T) {
	stateDir := t.TempDir()
	archivePath := filepath.Join(t.TempDir(), "test.tar")
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	tw.Close()
	if err := os.WriteFile(archivePath, buf.Bytes(), 0644); err != nil {
		t.Fatal(err)
	}
	root := newRootCmd()
	_, err := testExecute(root, "sync", "--takeout-archive", archivePath, "--state-dir", stateDir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestSyncWithDeleteAfter(t *testing.T) {
	stateDir := t.TempDir()
	archivePath := filepath.Join(t.TempDir(), "test.tar")
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	tw.Close()
	if err := os.WriteFile(archivePath, buf.Bytes(), 0644); err != nil {
		t.Fatal(err)
	}
	root := newRootCmd()
	_, err := testExecute(root, "sync", "--takeout-archive", archivePath, "--state-dir", stateDir, "--delete-after")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Stat(archivePath); err == nil {
		t.Fatal("expected archive to be deleted after sync")
	}
}

func TestSyncMutualExclusivity(t *testing.T) {
	root := newRootCmd()
	_, err := testExecute(root, "sync", "--takeout-dir", "/tmp/dir", "--takeout-archive", "/tmp/a.tgz")
	if err == nil {
		t.Fatal("expected error for mutually exclusive flags")
	}
	if !strings.Contains(err.Error(), "mutually exclusive") {
		t.Errorf("expected mutually exclusive error, got: %v", err)
	}
}

func TestSyncMissingBothFlags(t *testing.T) {
	root := newRootCmd()
	_, err := testExecute(root, "sync")
	if err == nil {
		t.Fatal("expected error for missing flags")
	}
	if !strings.Contains(err.Error(), "takeout-dir") && !strings.Contains(err.Error(), "takeout-archive") {
		t.Errorf("expected error mentioning takeout-dir or takeout-archive, got: %v", err)
	}
}

func TestSyncHelpShowsNewFlags(t *testing.T) {
	root := newRootCmd()
	output, err := testExecute(root, "sync", "--help")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, flag := range []string{"--takeout-archive", "--delete-after", "--twofa"} {
		if !strings.Contains(output, flag) {
			t.Errorf("expected flag %q in help output", flag)
		}
	}
}

func TestAlbumsFinalizeHelp(t *testing.T) {
	root := newRootCmd()
	output, err := testExecute(root, "albums-finalize", "--help")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(output, "albums-finalize") {
		t.Errorf("expected albums-finalize in help output")
	}
	if !strings.Contains(output, "--twofa") {
		t.Errorf("expected --twofa flag in albums-finalize help output")
	}
}

func TestAlbumsFinalizeNoDatabase(t *testing.T) {
	root := newRootCmd()
	_, err := testExecute(root, "albums-finalize", "--state-dir", "/nonexistent/path/that/does/not/exist")
	if err == nil {
		t.Fatal("expected error when state directory does not exist")
	}
}
