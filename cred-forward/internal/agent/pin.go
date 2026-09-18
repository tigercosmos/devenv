package agent

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
)

// PinLookup decides which GitHub login serves a request, regardless of the
// account the client asked for. Host is the link the request arrived on, or
// "" for the default socket. The second result is false when nothing is pinned.
type PinLookup interface {
	Pin(host string) (account string, pinned bool, err error)
}

// PinFile reads the pin on every call so `devenv server gh use` takes effect
// without a service restart. The format matches the client's account map:
// one "HOST ACCOUNT" pair per line, "*" for every host, "#" comments.
type PinFile struct {
	Path string
}

// ErrInvalidPin marks a pin file that names something other than a GitHub login.
var ErrInvalidPin = errors.New("invalid pin file")

// Pin implements PinLookup. A missing file pins nothing. A malformed file is
// an error so the agent fails closed instead of serving an unexpected login.
func (p PinFile) Pin(host string) (string, bool, error) {
	if p.Path == "" {
		return "", false, nil
	}
	file, err := os.Open(p.Path)
	if errors.Is(err, os.ErrNotExist) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("open pin file: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 4096), 4096)
	fallback := ""
	match := ""
	// The whole file is validated before any line is trusted, so a malformed
	// line after the matching one still fails closed.
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 || !protocol.ValidAccount(fields[1]) || (fields[0] != "*" && !protocol.ValidHost(fields[0])) {
			return "", false, fmt.Errorf("%w: %s", ErrInvalidPin, p.Path)
		}
		switch {
		case fields[0] == "*":
			if fallback == "" {
				fallback = fields[1]
			}
		case match == "" && host != "" && strings.EqualFold(fields[0], host):
			match = fields[1]
		}
	}
	if err := scanner.Err(); err != nil {
		return "", false, fmt.Errorf("%w: %s", ErrInvalidPin, p.Path)
	}
	if match != "" {
		return match, true, nil
	}
	if fallback != "" {
		return fallback, true, nil
	}
	return "", false, nil
}
