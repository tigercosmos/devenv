package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/tigercosmos/devenv/cred-forward/internal/client"
)

func main() {
	defaultPath, err := socketPath()
	if err != nil {
		fatal(err)
	}
	path := flag.String("socket", defaultPath, "forwarded Unix socket path")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: cred-client [-socket PATH] SERVICE [ACCOUNT]")
	}
	flag.Parse()
	if flag.NArg() < 1 || flag.NArg() > 2 {
		flag.Usage()
		os.Exit(2)
	}
	credential, err := client.Get(*path, flag.Arg(0), flag.Arg(1), 0)
	if err != nil {
		// Exit 3 tells the wrappers that no agent answered, so they may
		// offer the local login. Every other failure exits 1.
		fmt.Fprintf(os.Stderr, "cred-client: %v\n", err)
		if errors.Is(err, client.ErrUnreachable) {
			os.Exit(3)
		}
		os.Exit(1)
	}
	if _, err := fmt.Fprint(os.Stdout, credential); err != nil {
		fatal(errors.New("write credential"))
	}
}

func socketPath() (string, error) {
	if value := os.Getenv("CRED_FORWARD_SOCKET"); value != "" {
		return value, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("find home directory")
	}
	return filepath.Join(home, ".cache", "cred.sock"), nil
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "cred-client: %v\n", err)
	os.Exit(1)
}
