// Package provider supplies credentials without coupling the agent to one secret store.
package provider

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
)

var (
	ErrNotConfigured = errors.New("credential is not configured")
	ErrInvalidValue  = errors.New("credential must be a non-empty single line")
)

// Source retrieves one credential.
type Source interface {
	Credential(context.Context) (string, error)
}

// Registry maps protocol service names to provider chains.
type Registry map[string]Source

// Credential retrieves a credential from a registered source.
func (r Registry) Credential(ctx context.Context, service string) (string, error) {
	source, ok := r[service]
	if !ok {
		return "", fmt.Errorf("unknown service")
	}
	value, err := source.Credential(ctx)
	if err != nil {
		return "", err
	}
	if err := validate(value); err != nil {
		return "", err
	}
	return value, nil
}

// Env reads a credential from one environment variable.
type Env struct {
	Name   string
	Lookup func(string) (string, bool)
}

// Credential implements Source.
func (e Env) Credential(context.Context) (string, error) {
	lookup := e.Lookup
	if lookup == nil {
		lookup = os.LookupEnv
	}
	value, ok := lookup(e.Name)
	if !ok || value == "" {
		return "", ErrNotConfigured
	}
	return value, nil
}

// Command reads a credential from a shell command stored in an environment variable.
type Command struct {
	EnvName string
	Lookup  func(string) (string, bool)
	Timeout time.Duration
}

// Credential implements Source. It discards stderr and never includes output in errors.
func (c Command) Credential(ctx context.Context) (string, error) {
	lookup := c.Lookup
	if lookup == nil {
		lookup = os.LookupEnv
	}
	command, ok := lookup(c.EnvName)
	if !ok || strings.TrimSpace(command) == "" {
		return "", ErrNotConfigured
	}
	timeout := c.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	cmdCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(cmdCtx, "/bin/sh", "-c", command)
	cmd.Env = credentialCommandEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		return killProcessGroup(cmd)
	}
	cmd.WaitDelay = time.Second
	cmd.Stderr = io.Discard
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", errors.New("credential command failed")
	}
	if err := cmd.Start(); err != nil {
		return "", errors.New("credential command failed")
	}
	output, readErr := io.ReadAll(io.LimitReader(stdout, protocol.MaxCredential+2))
	tooLarge := len(output) > protocol.MaxCredential+1
	if tooLarge {
		_ = killProcessGroup(cmd)
	}
	waitErr := cmd.Wait()
	if tooLarge {
		return "", protocol.ErrCredentialTooLarge
	}
	if cmdCtx.Err() != nil || readErr != nil || waitErr != nil {
		return "", errors.New("credential command failed")
	}
	value := strings.TrimSuffix(string(output), "\n")
	value = strings.TrimSuffix(value, "\r")
	return value, nil
}

func killProcessGroup(cmd *exec.Cmd) error {
	err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	if errors.Is(err, syscall.ESRCH) {
		return os.ErrProcessDone
	}
	return err
}

func credentialCommandEnv() []string {
	blocked := map[string]struct{}{
		"GH_TOKEN": {}, "GITHUB_TOKEN": {},
		"ANTHROPIC_API_KEY": {}, "ANTHROPIC_AUTH_TOKEN": {},
		"CLAUDE_CODE_OAUTH_TOKEN": {}, "OPENAI_API_KEY": {},
		"CODEX_ACCESS_TOKEN": {},
	}
	filtered := make([]string, 0, len(os.Environ()))
	for _, entry := range os.Environ() {
		name, _, _ := strings.Cut(entry, "=")
		if strings.HasPrefix(name, "CRED_AGENT_") || strings.HasPrefix(name, "CRED_FORWARD_") {
			continue
		}
		if _, found := blocked[name]; found {
			continue
		}
		filtered = append(filtered, entry)
	}
	return filtered
}

// Chain returns the first configured source.
type Chain []Source

// Credential implements Source.
func (c Chain) Credential(ctx context.Context) (string, error) {
	for _, source := range c {
		value, err := source.Credential(ctx)
		if errors.Is(err, ErrNotConfigured) {
			continue
		}
		return value, err
	}
	return "", ErrNotConfigured
}

// NewDefaultRegistry uses explicit cred-agent variables and command helpers.
// Standard CLI variables are considered only with CRED_AGENT_INHERIT_ENV=1.
func NewDefaultRegistry() Registry {
	registry := Registry{
		"github": Chain{
			Env{Name: "CRED_AGENT_GITHUB"},
			Command{EnvName: "CRED_AGENT_GITHUB_COMMAND"},
		},
		"anthropic": Chain{
			Env{Name: "CRED_AGENT_ANTHROPIC"},
			Command{EnvName: "CRED_AGENT_ANTHROPIC_COMMAND"},
		},
		"anthropicoauth": Chain{
			Env{Name: "CRED_AGENT_ANTHROPIC_OAUTH"},
			Command{EnvName: "CRED_AGENT_ANTHROPIC_OAUTH_COMMAND"},
		},
		"openai": Chain{
			Env{Name: "CRED_AGENT_OPENAI"},
			Command{EnvName: "CRED_AGENT_OPENAI_COMMAND"},
		},
		"openaichatgpt": Chain{
			Env{Name: "CRED_AGENT_OPENAI_CHATGPT"},
			Command{EnvName: "CRED_AGENT_OPENAI_CHATGPT_COMMAND"},
		},
		"openaiaccount": Chain{
			Env{Name: "CRED_AGENT_OPENAI_ACCOUNT"},
			Command{EnvName: "CRED_AGENT_OPENAI_ACCOUNT_COMMAND"},
		},
	}
	if os.Getenv("CRED_AGENT_INHERIT_ENV") == "1" {
		registry["github"] = append(registry["github"].(Chain), Env{Name: "GH_TOKEN"}, Env{Name: "GITHUB_TOKEN"})
		registry["anthropic"] = append(registry["anthropic"].(Chain), Env{Name: "ANTHROPIC_API_KEY"})
		registry["anthropicoauth"] = append(registry["anthropicoauth"].(Chain), Env{Name: "CLAUDE_CODE_OAUTH_TOKEN"})
		registry["openai"] = append(registry["openai"].(Chain), Env{Name: "OPENAI_API_KEY"})
	}
	return registry
}

func validate(value string) error {
	if value == "" || strings.ContainsAny(value, "\x00\r\n") {
		return ErrInvalidValue
	}
	if len(value) > protocol.MaxCredential {
		return protocol.ErrCredentialTooLarge
	}
	return nil
}
