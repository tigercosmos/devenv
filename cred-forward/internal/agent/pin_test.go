package agent_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/tigercosmos/devenv/cred-forward/internal/agent"
	"github.com/tigercosmos/devenv/cred-forward/internal/client"
	"github.com/tigercosmos/devenv/cred-forward/internal/provider"
)

func writePin(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestPinFileResolvesHostThenFallback(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gh-account")
	pin := agent.PinFile{Path: path}

	if _, found, err := pin.Pin("sim4"); err != nil || found {
		t.Fatalf("missing file: found=%v err=%v", found, err)
	}
	writePin(t, path, "# Managed by devenv cred-forward.\r\n\r\n* tigercosmos\r\nSIM4 anchi-t2\r\n")
	for host, want := range map[string]string{"sim4": "anchi-t2", "sim0": "tigercosmos", "": "tigercosmos"} {
		got, found, err := pin.Pin(host)
		if err != nil || !found || got != want {
			t.Fatalf("host %q: got %q found=%v err=%v, want %q", host, got, found, err, want)
		}
	}
	writePin(t, path, "sim4 anchi-t2\n")
	if _, found, err := pin.Pin("sim0"); err != nil || found {
		t.Fatalf("unlisted host without fallback: found=%v err=%v", found, err)
	}
	writePin(t, path, "* bad;login\n")
	if _, _, err := pin.Pin("sim4"); !errors.Is(err, agent.ErrInvalidPin) {
		t.Fatalf("malformed file: got %v", err)
	}
	writePin(t, path, "sim4 anchi-t2\n* bad;login\n")
	if _, _, err := pin.Pin("sim4"); !errors.Is(err, agent.ErrInvalidPin) {
		t.Fatalf("malformed line after the match: got %v", err)
	}
	writePin(t, path, "* one two\n")
	if _, _, err := pin.Pin("sim4"); !errors.Is(err, agent.ErrInvalidPin) {
		t.Fatalf("three fields: got %v", err)
	}
	if _, found, err := (agent.PinFile{}).Pin("sim4"); err != nil || found {
		t.Fatalf("empty path: found=%v err=%v", found, err)
	}
}

func TestServerAppliesGitHubPinPerHostSocket(t *testing.T) {
	pinPath := filepath.Join(t.TempDir(), "gh-account")
	server := agent.Server{
		Providers: provider.Registry{
			"github": accountSource{logins: map[string]string{
				"": "active-secret", "anchi-t2": "work-secret", "tigercosmos": "personal-secret",
			}},
			"anthropic": accountSource{logins: map[string]string{"": "anthropic-secret"}},
		},
		GitHubPin: agent.PinFile{Path: pinPath},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sockets := map[string]string{}
	for _, host := range []string{"", "sim0", "sim4"} {
		name := "agent.sock"
		if host != "" {
			name = "agent-" + host + ".sock"
		}
		socket := shortSocketPath(t, name)
		listener, cleanup, err := agent.Listen(socket)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = cleanup() })
		sockets[host] = socket
		go func(host string) { _ = server.ServeHost(ctx, listener, host) }(host)
	}
	get := func(host, account string) string {
		t.Helper()
		got, err := client.Get(sockets[host], "github", account, 0)
		if err != nil {
			t.Fatalf("host %q account %q: %v", host, account, err)
		}
		return got
	}

	// No pin: the client's choice stands on every socket.
	if got := get("sim4", "tigercosmos"); got != "personal-secret" {
		t.Fatalf("unpinned request returned %q", got)
	}
	// A host pin beats the requested account; the fallback covers the rest,
	// including the default socket.
	writePin(t, pinPath, "* tigercosmos\nsim4 anchi-t2\n")
	if got := get("sim4", "tigercosmos"); got != "work-secret" {
		t.Fatalf("host pin ignored: %q", got)
	}
	if got := get("sim4", ""); got != "work-secret" {
		t.Fatalf("host pin ignored for default account: %q", got)
	}
	if got := get("sim0", "anchi-t2"); got != "personal-secret" {
		t.Fatalf("fallback pin ignored: %q", got)
	}
	if got := get("", "anchi-t2"); got != "personal-secret" {
		t.Fatalf("fallback pin ignored on the default socket: %q", got)
	}
	// Other services never see the pin.
	if got, err := client.Get(sockets["sim4"], "anthropic", "", 0); err != nil || got != "anthropic-secret" {
		t.Fatalf("anthropic through a pinned host: %q %v", got, err)
	}
	// Removing the file takes effect on the next request, without a restart.
	if err := os.Remove(pinPath); err != nil {
		t.Fatal(err)
	}
	if got := get("sim4", ""); got != "active-secret" {
		t.Fatalf("removed pin still applied: %q", got)
	}
	// A malformed pin fails closed.
	writePin(t, pinPath, "* not a login here\n")
	if _, err := client.Get(sockets["sim4"], "github", "", 0); err == nil {
		t.Fatal("malformed pin file unexpectedly served a credential")
	}
}
