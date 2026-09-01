// Package client retrieves credentials from a forwarded cred-agent socket.
package client

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
)

// Get retrieves one credential.
func Get(socketPath, service string, timeout time.Duration) (string, error) {
	if !protocol.ValidService(service) {
		return "", fmt.Errorf("service must be %s", protocol.ServiceList)
	}
	if timeout == 0 {
		timeout = 20 * time.Second
	}
	conn, err := net.DialTimeout("unix", socketPath, timeout)
	if err != nil {
		return "", fmt.Errorf("forwarded credential socket is unavailable at %s", socketPath)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))
	if err := protocol.WriteRequest(conn, service); err != nil {
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
