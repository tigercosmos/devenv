package client_test

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/client"
)

func TestGetReportsResponseTimeout(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "cf-client-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	listener, err := net.Listen("unix", filepath.Join(dir, "agent.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr == nil {
			defer conn.Close()
			time.Sleep(time.Second)
		}
	}()

	_, err = client.Get(listener.Addr().String(), "github", "", 50*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "timed out waiting") {
		t.Fatalf("got %v", err)
	}
}

func TestGetListsEverySupportedService(t *testing.T) {
	_, err := client.Get("/does/not/matter", "invalid", "", time.Second)
	if err == nil {
		t.Fatal("invalid service unexpectedly accepted")
	}
	for _, service := range []string{
		"github", "anthropic", "anthropicoauth", "openai", "openaichatgpt", "openaiaccount",
	} {
		if !strings.Contains(err.Error(), service) {
			t.Fatalf("error %q does not list %q", err, service)
		}
	}
}

func TestGetNamesMissingAndStaleSockets(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "cf-client-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	path := filepath.Join(dir, "agent.sock")

	_, err = client.Get(path, "github", "", time.Second)
	if err == nil || !strings.Contains(err.Error(), "no forwarded credential socket") {
		t.Fatalf("missing socket: got %v", err)
	}

	// A listener that closes without unlinking leaves the file that a
	// finished SSH session leaves behind.
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	listener.SetUnlinkOnClose(false)
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	_, err = client.Get(path, "github", "", time.Second)
	if err == nil || !strings.Contains(err.Error(), "stale credential socket") {
		t.Fatalf("stale socket: got %v", err)
	}
}
