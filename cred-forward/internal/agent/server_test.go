package agent_test

import (
	"bufio"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/agent"
	"github.com/tigercosmos/devenv/cred-forward/internal/client"
	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
	"github.com/tigercosmos/devenv/cred-forward/internal/provider"
)

type temporaryAcceptError struct{}

func (temporaryAcceptError) Error() string   { return "temporary accept error" }
func (temporaryAcceptError) Timeout() bool   { return false }
func (temporaryAcceptError) Temporary() bool { return true }

type retryListener struct {
	accepts int
}

func (l *retryListener) Accept() (net.Conn, error) {
	l.accepts++
	if l.accepts == 1 {
		return nil, temporaryAcceptError{}
	}
	return nil, net.ErrClosed
}

func (*retryListener) Close() error   { return nil }
func (*retryListener) Addr() net.Addr { return nil }

type staticSource struct {
	value string
	err   error
}

func (s staticSource) Credential(context.Context) (string, error) {
	return s.value, s.err
}

func shortSocketPath(t *testing.T, name string) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "cf-agent-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, name)
}

func TestClientServerRoundTrip(t *testing.T) {
	socket := shortSocketPath(t, "agent.sock")
	listener, cleanup, err := agent.Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cleanup() })
	info, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode is %o, want 600", info.Mode().Perm())
	}

	registry := provider.Registry{
		"github":    staticSource{value: "github-secret"},
		"anthropic": staticSource{value: "anthropic-secret"},
		"openai":    staticSource{value: "openai-secret"},
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = (agent.Server{Providers: registry}).Serve(ctx, listener) }()

	for service, want := range map[string]string{
		"github": "github-secret", "anthropic": "anthropic-secret", "openai": "openai-secret",
	} {
		got, err := client.Get(socket, service, 0)
		if err != nil {
			t.Fatalf("%s: %v", service, err)
		}
		if got != want {
			t.Fatalf("%s: got %q, want %q", service, got, want)
		}
	}
}

func TestServerRetriesTemporaryAcceptError(t *testing.T) {
	listener := &retryListener{}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := (agent.Server{}).Serve(ctx, listener); err != nil {
		t.Fatal(err)
	}
	if listener.accepts != 2 {
		t.Fatalf("Accept called %d times, want 2", listener.accepts)
	}
}

func TestProviderErrorDoesNotLeakCredentialMaterial(t *testing.T) {
	const secret = "secret-provider-output"
	socket := shortSocketPath(t, "agent.sock")
	listener, cleanup, err := agent.Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	registry := provider.Registry{"github": staticSource{err: errors.New(secret)}}
	go func() { _ = (agent.Server{Providers: registry}).Serve(ctx, listener) }()

	conn, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := protocol.WriteRequest(conn, "github"); err != nil {
		t.Fatal(err)
	}
	credential, code, err := protocol.ReadResponse(bufio.NewReader(conn))
	if err != nil {
		t.Fatal(err)
	}
	if credential != "" || code != "unavailable" || strings.Contains(code, secret) {
		t.Fatalf("unsafe response: credential=%q code=%q", credential, code)
	}
}

func TestUnknownServiceReturnsFixedError(t *testing.T) {
	socket := shortSocketPath(t, "agent.sock")
	listener, cleanup, err := agent.Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = (agent.Server{Providers: provider.Registry{}}).Serve(ctx, listener) }()

	conn, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("CRED/1 GET other\n")); err != nil {
		t.Fatal(err)
	}
	_, code, err := protocol.ReadResponse(bufio.NewReader(conn))
	if err != nil || code != "unknown-service" {
		t.Fatalf("got code %q and error %v", code, err)
	}
}

func TestUnavailableSocketFailsClearly(t *testing.T) {
	socket := shortSocketPath(t, "missing.sock")
	_, err := client.Get(socket, "github", 0)
	if err == nil || !strings.Contains(err.Error(), "forwarded credential socket is unavailable") {
		t.Fatalf("got %v", err)
	}
}

func TestListenRefusesRegularFile(t *testing.T) {
	path := shortSocketPath(t, "agent.sock")
	if err := os.WriteFile(path, []byte("do not remove"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, err := agent.Listen(path)
	if err == nil {
		t.Fatal("Listen unexpectedly replaced a regular file")
	}
	got, readErr := os.ReadFile(path)
	if readErr != nil || string(got) != "do not remove" {
		t.Fatalf("regular file changed: %q, %v", got, readErr)
	}
}

func TestListenRefusesSecondAgentWithoutRemovingLiveSocket(t *testing.T) {
	path := shortSocketPath(t, "agent.sock")
	listener, cleanup, err := agent.Listen(path)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	if listener.Addr() == nil {
		t.Fatal("first listener has no address")
	}

	_, _, err = agent.Listen(path)
	if err == nil || !strings.Contains(err.Error(), "socket is already in use") {
		t.Fatalf("second Listen returned %v", err)
	}
	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatalf("first agent socket was disrupted: %v", err)
	}
	_ = conn.Close()
}

func TestListenRejectsLongSocketPathClearly(t *testing.T) {
	path := filepath.Join("/tmp", strings.Repeat("x", 120), "agent.sock")
	_, _, err := agent.Listen(path)
	if err == nil || !strings.Contains(err.Error(), "socket path is too long") {
		t.Fatalf("got %v", err)
	}
}
