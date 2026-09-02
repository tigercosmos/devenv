package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRotatingLogWriterBoundsLogSize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cred-agent.log")
	writer := &rotatingLogWriter{path: path, maxBytes: 16}
	first := []byte("first record\n")
	second := []byte("second record\n")
	third := []byte("third record\n")
	if _, err := writer.Write(first); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(second); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(third); err != nil {
		t.Fatal(err)
	}

	current, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(current) != string(third) {
		t.Fatalf("current log is %q, want %q", current, third)
	}
	previous, err := os.ReadFile(path + ".1")
	if err != nil {
		t.Fatal(err)
	}
	if string(previous) != string(second) {
		t.Fatalf("previous log is %q, want %q", previous, second)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("log directory has %d files, want 2", len(entries))
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("log mode is %o, want 600", info.Mode().Perm())
	}
}

func TestNewAuditOutputRejectsRelativePath(t *testing.T) {
	if _, err := newAuditOutput("cred-agent.log"); err == nil {
		t.Fatal("newAuditOutput accepted a relative path")
	}
}
