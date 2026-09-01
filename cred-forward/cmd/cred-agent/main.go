package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/tigercosmos/devenv/cred-forward/internal/agent"
	"github.com/tigercosmos/devenv/cred-forward/internal/provider"
)

func main() {
	defaultPath, err := socketPath("CRED_AGENT_SOCKET", "cred-agent.sock")
	if err != nil {
		fatal(err)
	}
	path := flag.String("socket", defaultPath, "Unix socket path")
	flag.Parse()
	if flag.NArg() != 0 {
		fatal(errors.New("usage: cred-agent [-socket PATH]"))
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	listener, cleanup, err := agent.Listen(*path)
	if err != nil {
		fatal(err)
	}
	fmt.Fprintf(os.Stderr, "cred-agent: listening on %s\n", *path)
	server := agent.Server{Providers: provider.NewDefaultRegistry()}
	serveErr := server.Serve(ctx, listener)
	cleanupErr := cleanup()
	if serveErr != nil {
		fatal(serveErr)
	}
	if cleanupErr != nil {
		fatal(cleanupErr)
	}
}

func socketPath(envName, name string) (string, error) {
	if value := os.Getenv(envName); value != "" {
		return value, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("find home directory")
	}
	return filepath.Join(home, ".cache", name), nil
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "cred-agent: %v\n", err)
	os.Exit(1)
}
