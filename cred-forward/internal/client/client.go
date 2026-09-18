// Package client retrieves credentials from a forwarded cred-agent socket.
package client

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"syscall"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
)

// dial names the two states a finished SSH forward leaves behind: no socket
// file, or a file that no session listens on any more.
func dial(socketPath string, timeout time.Duration) (net.Conn, error) {
	conn, err := net.DialTimeout("unix", socketPath, timeout)
	if err == nil {
		return conn, nil
	}
	switch {
	case errors.Is(err, os.ErrNotExist):
		return nil, fmt.Errorf("no forwarded credential socket at %s: is the cred-forward link connected?", socketPath)
	case errors.Is(err, syscall.ECONNREFUSED):
		return nil, fmt.Errorf("stale credential socket at %s: no SSH session forwards it", socketPath)
	}
	return nil, fmt.Errorf("forwarded credential socket is unavailable at %s", socketPath)
}

// Get retrieves one credential. An empty account selects the default login.
func Get(socketPath, service, account string, timeout time.Duration) (string, error) {
	if !protocol.ValidService(service) {
		return "", fmt.Errorf("service must be %s", protocol.ServiceList)
	}
	if account != "" && !protocol.ValidAccount(account) {
		return "", errors.New("account must be a GitHub login: letters, digits, and hyphens")
	}
	if timeout == 0 {
		timeout = 20 * time.Second
	}
	conn, err := dial(socketPath, timeout)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	if err := protocol.WriteRequest(conn, service, account); err != nil {
		return "", errors.New("send credential request")
	}
	credential, remoteCode, err := protocol.ReadResponse(bufio.NewReaderSize(conn, protocol.MaxHeaderSize))
	if err != nil {
		if errors.Is(err, os.ErrDeadlineExceeded) {
			return "", errors.New("timed out waiting for the credential agent")
		}
		return "", errors.New("credential agent returned an invalid response")
	}
	if remoteCode != "" {
		return "", fmt.Errorf("credential agent error: %s", remoteCode)
	}
	return credential, nil
}
