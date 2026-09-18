// Package protocol implements the bounded cred-forward wire protocol.
package protocol

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	Version       = "CRED/1"
	MaxHeaderSize = 256
	MaxCredential = 64 * 1024
	MaxAccount    = 39
	ServiceList   = "github, anthropic, anthropicoauth, openai, openaichatgpt, or openaiaccount"
)

var (
	ErrInvalidRequest     = errors.New("invalid request")
	ErrInvalidResponse    = errors.New("invalid response")
	ErrCredentialTooLarge = errors.New("credential is too large")
)

// WriteRequest writes one credential request. An empty account selects the
// service's default login.
func WriteRequest(w io.Writer, service, account string) error {
	if !ValidService(service) {
		return ErrInvalidRequest
	}
	if account == "" {
		_, err := fmt.Fprintf(w, "%s GET %s\n", Version, service)
		return err
	}
	if !ValidAccount(account) {
		return ErrInvalidRequest
	}
	_, err := fmt.Fprintf(w, "%s GET %s %s\n", Version, service, account)
	return err
}

// ReadRequest reads one credential request and returns its service and
// optional account.
func ReadRequest(r *bufio.Reader) (service, account string, err error) {
	line, err := readHeader(r)
	if err != nil {
		return "", "", ErrInvalidRequest
	}
	parts := strings.Split(line, " ")
	if len(parts) < 3 || len(parts) > 4 || parts[0] != Version || parts[1] != "GET" || !validServiceName(parts[2]) {
		return "", "", ErrInvalidRequest
	}
	if len(parts) == 4 {
		if !ValidAccount(parts[3]) {
			return "", "", ErrInvalidRequest
		}
		account = parts[3]
	}
	return parts[2], account, nil
}

// WriteCredential writes a successful, length-framed response.
func WriteCredential(w io.Writer, credential string) error {
	if len(credential) > MaxCredential {
		return ErrCredentialTooLarge
	}
	if _, err := fmt.Fprintf(w, "%s OK %d\n", Version, len(credential)); err != nil {
		return err
	}
	_, err := io.WriteString(w, credential)
	return err
}

// WriteError writes a safe error code. The code must never contain provider output.
func WriteError(w io.Writer, code string) error {
	if !validCode(code) {
		code = "internal"
	}
	_, err := fmt.Fprintf(w, "%s ERR %s\n", Version, code)
	return err
}

// ReadResponse reads one response and returns either its credential or safe error code.
func ReadResponse(r *bufio.Reader) (credential string, remoteCode string, err error) {
	line, err := readHeader(r)
	if err != nil {
		return "", "", errors.Join(ErrInvalidResponse, err)
	}
	parts := strings.Split(line, " ")
	if len(parts) != 3 || parts[0] != Version {
		return "", "", ErrInvalidResponse
	}
	if parts[1] == "ERR" {
		if !validCode(parts[2]) {
			return "", "", ErrInvalidResponse
		}
		return "", parts[2], nil
	}
	if parts[1] != "OK" {
		return "", "", ErrInvalidResponse
	}
	size, err := strconv.Atoi(parts[2])
	if err != nil || size < 0 || size > MaxCredential {
		return "", "", ErrInvalidResponse
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(r, payload); err != nil {
		return "", "", errors.Join(ErrInvalidResponse, err)
	}
	return string(payload), "", nil
}

// ValidService reports whether a service is part of protocol version 1.
func ValidService(service string) bool {
	switch service {
	case "github", "anthropic", "anthropicoauth", "openai", "openaichatgpt", "openaiaccount":
		return true
	default:
		return false
	}
}

// ValidAccount reports whether an account name uses the GitHub login syntax:
// up to 39 ASCII letters, digits, or hyphens, without a leading hyphen.
func ValidAccount(account string) bool {
	if account == "" || len(account) > MaxAccount || account[0] == '-' {
		return false
	}
	for _, char := range account {
		switch {
		case char >= 'a' && char <= 'z', char >= 'A' && char <= 'Z', char >= '0' && char <= '9', char == '-':
		default:
			return false
		}
	}
	return true
}

// ValidHost reports whether a name is an SSH host alias the agent accepts:
// letters, digits, dots, underscores, and hyphens, without a leading hyphen.
func ValidHost(host string) bool {
	if host == "" || host[0] == '-' {
		return false
	}
	for _, char := range host {
		switch {
		case char >= 'a' && char <= 'z', char >= 'A' && char <= 'Z', char >= '0' && char <= '9', char == '.', char == '_', char == '-':
		default:
			return false
		}
	}
	return true
}

func readHeader(r *bufio.Reader) (string, error) {
	line, err := r.ReadSlice('\n')
	if err != nil {
		return "", err
	}
	if len(line) == 0 || len(line) > MaxHeaderSize || line[len(line)-1] != '\n' {
		return "", errors.New("invalid header")
	}
	return string(line[:len(line)-1]), nil
}

func validServiceName(service string) bool {
	if service == "" || len(service) > 32 {
		return false
	}
	for _, char := range service {
		if char < 'a' || char > 'z' {
			return false
		}
	}
	return true
}

func validCode(code string) bool {
	switch code {
	case "invalid-request", "unknown-service", "unavailable", "internal":
		return true
	default:
		return false
	}
}
