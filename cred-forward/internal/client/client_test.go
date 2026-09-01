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

	_, err = client.Get(listener.Addr().String(), "github", 50*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "timed out waiting") {
		t.Fatalf("got %v", err)
	}
}

func TestGetListsEverySupportedService(t *testing.T) {
	_, err := client.Get("/does/not/matter", "invalid", time.Second)
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
