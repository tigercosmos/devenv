package agent_test

import (
	"bufio"
	"context"
	"errors"
	"fmt"
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

type singleConnListener struct {
	conn net.Conn
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

func (listener *singleConnListener) Accept() (net.Conn, error) {
	if listener.conn == nil {
		return nil, net.ErrClosed
	}
	conn := listener.conn
	listener.conn = nil
	return conn, nil
}

func (*singleConnListener) Close() error   { return nil }
func (*singleConnListener) Addr() net.Addr { return nil }

type staticSource struct {
	value string
	err   error
}

type blockingSource struct {
	started chan<- struct{}
	release <-chan struct{}
	value   string
}

type auditWriter chan string

func (writer auditWriter) Write(payload []byte) (int, error) {
	writer <- string(append([]byte(nil), payload...))
	return len(payload), nil
}

func (s staticSource) Credential(context.Context) (string, error) {
	return s.value, s.err
}

func (source blockingSource) Credential(context.Context) (string, error) {
	close(source.started)
	<-source.release
	return source.value, nil
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

func TestAuditLogRecordsRequestMetadataWithoutCredential(t *testing.T) {
	const secret = "github-secret"
	socket := shortSocketPath(t, "agent.sock")
	listener, cleanup, err := agent.Listen(socket)
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	audit := make(auditWriter, 8)
	server := agent.Server{
		Providers: provider.Registry{
			"github":    staticSource{value: secret},
			"anthropic": staticSource{err: errors.New("provider failed")},
			"openai":    staticSource{value: strings.Repeat("x", protocol.MaxCredential+1)},
		},
		AuditLog: agent.NewAuditLogger(audit),
	}
	go func() { _ = server.Serve(ctx, listener) }()

	if _, err := client.Get(socket, "github", 0); err != nil {
		t.Fatal(err)
	}
	lines := []string{readAuditLine(t, audit, "github", "ok")}
	if _, err := client.Get(socket, "anthropic", 0); err == nil {
		t.Fatal("anthropic request unexpectedly succeeded")
	}
	lines = append(lines, readAuditLine(t, audit, "anthropic", "unavailable"))
	if _, err := client.Get(socket, "openai", 0); err == nil {
		t.Fatal("oversized credential request unexpectedly succeeded")
	}
	lines = append(lines, readAuditLine(t, audit, "openai", "unavailable"))
	if code := rawRequest(t, socket, "CRED/1 GET other\n"); code != "unknown-service" {
		t.Fatalf("unknown service returned %q", code)
	}
	lines = append(lines, readAuditLine(t, audit, "other", "unknown-service"))
	if code := rawRequest(t, socket, "not-a-request\n"); code != "invalid-request" {
		t.Fatalf("invalid request returned %q", code)
	}
	lines = append(lines, readAuditLine(t, audit, "-", "invalid-request"))
	if strings.Contains(strings.Join(lines, "\n"), secret) {
		t.Fatalf("audit log contains credential value: %q", lines)
	}
}

func readAuditLine(t *testing.T, audit auditWriter, service, status string) string {
	return readAuditLineForPeer(t, audit, service, status, fmt.Sprint(os.Getpid()))
}

func readAuditLineForPeer(t *testing.T, audit auditWriter, service, status, peer string) string {
	t.Helper()
	var line string
	select {
	case line = <-audit:
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for audit record")
	}
	line = strings.TrimSpace(line)
	fields := strings.Fields(line)
	if len(fields) != 6 || fields[0] != "cred-agent:" || fields[1] != "request" {
		t.Fatalf("audit log has an invalid production prefix or field count: %q", line)
	}
	timestamp := strings.TrimPrefix(fields[2], "timestamp=")
	if _, err := time.Parse(time.RFC3339, timestamp); err != nil {
		t.Fatalf("audit timestamp %q is invalid: %v", timestamp, err)
	}
	wantMetadata := fmt.Sprintf("service=%s status=%s peer_pid=%s", service, status, peer)
	if strings.Join(fields[3:], " ") != wantMetadata {
		t.Fatalf("audit metadata is %q, want %q", strings.Join(fields[3:], " "), wantMetadata)
	}
	return line
}

func rawRequest(t *testing.T, socket, request string) string {
	t.Helper()
	conn, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(request)); err != nil {
		t.Fatal(err)
	}
	credential, code, err := protocol.ReadResponse(bufio.NewReader(conn))
	if err != nil {
		t.Fatal(err)
	}
	if credential != "" {
		t.Fatalf("request returned unexpected credential %q", credential)
	}
	return code
}

func TestAuditLogRecordsInternalWriteFailure(t *testing.T) {
	const secret = "github-secret"
	serverConn, clientConn := net.Pipe()
	started := make(chan struct{})
	release := make(chan struct{})
	audit := make(auditWriter, 1)
	server := agent.Server{
		Providers: provider.Registry{
			"github": blockingSource{started: started, release: release, value: secret},
		},
		AuditLog: agent.NewAuditLogger(audit),
	}
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- server.Serve(context.Background(), &singleConnListener{conn: serverConn})
	}()
	if err := protocol.WriteRequest(clientConn, "github"); err != nil {
		t.Fatal(err)
	}
	<-started
	if err := clientConn.Close(); err != nil {
		t.Fatal(err)
	}
	close(release)
	line := readAuditLineForPeer(t, audit, "github", "internal", "unknown")
	if strings.Contains(line, secret) {
		t.Fatalf("audit log contains credential value: %q", line)
	}
	if err := <-serveDone; err != nil {
		t.Fatal(err)
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
