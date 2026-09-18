package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"github.com/tigercosmos/devenv/cred-forward/internal/agent"
	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
	"github.com/tigercosmos/devenv/cred-forward/internal/provider"
)

// hostSockets collects repeated -host-socket HOST=PATH flags. Each link
// forwards its own local socket, so the agent knows which remote host is
// asking and can apply a per-host GitHub pin.
type hostSockets map[string]string

// String prints the flag default, which is always empty.
func (hostSockets) String() string { return "" }

func (h hostSockets) Set(value string) error {
	host, path, ok := strings.Cut(value, "=")
	if !ok || host == "" || path == "" || host == "*" {
		return errors.New("expected HOST=PATH")
	}
	if !protocol.ValidHost(host) {
		return fmt.Errorf("invalid host name: %s", host)
	}
	if _, found := h[host]; found {
		return fmt.Errorf("host listed twice: %s", host)
	}
	h[host] = path
	return nil
}

func main() {
	defaultPath, err := homePath("CRED_AGENT_SOCKET", ".cache", "cred-agent.sock")
	if err != nil {
		fatal(err)
	}
	defaultPin, err := homePath("CRED_AGENT_GITHUB_PIN", ".config", "cred-forward", "gh-account")
	if err != nil {
		fatal(err)
	}
	path := flag.String("socket", defaultPath, "Unix socket path")
	pinPath := flag.String("github-pin", defaultPin, "file that pins the GitHub login per host")
	perHost := hostSockets{}
	flag.Var(perHost, "host-socket", "additional HOST=PATH socket for one forwarded link (repeatable)")
	flag.Parse()
	if flag.NArg() != 0 {
		fatal(errors.New("usage: cred-agent [-socket PATH] [-github-pin FILE] [-host-socket HOST=PATH]..."))
	}
	auditOutput, err := newAuditOutput(os.Getenv("CRED_AGENT_AUDIT_LOG"))
	if err != nil {
		fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	type endpoint struct {
		host     string
		listener net.Listener
		cleanup  func() error
	}
	var endpoints []endpoint
	closeAll := func() error {
		var errs []error
		for _, ep := range endpoints {
			errs = append(errs, ep.cleanup())
		}
		return errors.Join(errs...)
	}
	listenOn := func(host, socketPath string) {
		listener, cleanup, err := agent.Listen(socketPath)
		if err != nil {
			_ = closeAll()
			fatal(fmt.Errorf("%s: %w", socketPath, err))
		}
		endpoints = append(endpoints, endpoint{host: host, listener: listener, cleanup: cleanup})
		if host == "" {
			fmt.Fprintf(auditOutput, "cred-agent: listening on %s\n", socketPath)
		} else {
			fmt.Fprintf(auditOutput, "cred-agent: listening on %s for %s\n", socketPath, host)
		}
	}
	listenOn("", *path)
	for host, socketPath := range perHost {
		listenOn(host, socketPath)
	}

	server := agent.Server{
		Providers: provider.NewDefaultRegistry(),
		AuditLog:  agent.NewAuditLogger(auditOutput),
		GitHubPin: agent.PinFile{Path: *pinPath},
	}
	// One failing listener stops the whole agent; the service manager restarts it.
	serveCtx, cancelServe := context.WithCancel(ctx)
	var serving sync.WaitGroup
	serveErrs := make([]error, len(endpoints))
	for i, ep := range endpoints {
		serving.Add(1)
		go func(i int, ep endpoint) {
			defer serving.Done()
			if err := server.ServeHost(serveCtx, ep.listener, ep.host); err != nil {
				serveErrs[i] = fmt.Errorf("%s: %w", ep.listener.Addr(), err)
				cancelServe()
			}
		}(i, ep)
	}
	serving.Wait()
	cancelServe()
	serveErr := errors.Join(serveErrs...)
	cleanupErr := closeAll()
	if serveErr != nil {
		fatal(serveErr)
	}
	if cleanupErr != nil {
		fatal(cleanupErr)
	}
}

func homePath(envName string, parts ...string) (string, error) {
	if value := os.Getenv(envName); value != "" {
		return value, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("find home directory")
	}
	return filepath.Join(append([]string{home}, parts...)...), nil
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "cred-agent: %v\n", err)
	os.Exit(1)
}
