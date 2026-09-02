// Package provider supplies credentials without coupling the agent to one secret store.
package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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
	return runCommand(cmdCtx, "/bin/sh", []string{"-c", command})
}

// Executable reads a credential from a fixed executable and argument list.
// It does not invoke a shell.
type Executable struct {
	Name    string
	Args    []string
	Timeout time.Duration
}

// Credential implements Source.
func (e Executable) Credential(ctx context.Context) (string, error) {
	if _, err := exec.LookPath(e.Name); err != nil {
		return "", ErrNotConfigured
	}
	timeout := e.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	cmdCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return runCommand(cmdCtx, e.Name, e.Args)
}

func runCommand(ctx context.Context, name string, args []string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
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
	if ctx.Err() != nil || readErr != nil || waitErr != nil {
		return "", errors.New("credential command failed")
	}
	value := strings.TrimSuffix(string(output), "\n")
	value = strings.TrimSuffix(value, "\r")
	return value, nil
}

// TextFile reads a credential from an owner-only local file.
type TextFile struct {
	Path string
}

// Credential implements Source.
func (f TextFile) Credential(context.Context) (string, error) {
	path, err := expandHome(f.Path)
	if err != nil {
		return "", err
	}
	data, err := readPrivateFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", ErrNotConfigured
	}
	if err != nil {
		return "", errors.New("credential file is unavailable")
	}
	return strings.TrimSuffix(strings.TrimSuffix(string(data), "\n"), "\r"), nil
}

// JSONFile reads one nested string value from an owner-only JSON file.
type JSONFile struct {
	Path string
	Keys []string
}

// Credential implements Source.
func (f JSONFile) Credential(context.Context) (string, error) {
	path, err := expandHome(f.Path)
	if err != nil {
		return "", err
	}
	data, err := readPrivateFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", ErrNotConfigured
	}
	if err != nil {
		return "", errors.New("credential file is unavailable")
	}
	var value any
	if json.Unmarshal(data, &value) != nil {
		return "", errors.New("credential file is invalid")
	}
	for _, key := range f.Keys {
		object, ok := value.(map[string]any)
		if !ok {
			return "", ErrNotConfigured
		}
		value, ok = object[key]
		if !ok {
			return "", ErrNotConfigured
		}
	}
	credential, ok := value.(string)
	if !ok || credential == "" {
		return "", ErrNotConfigured
	}
	return credential, nil
}

func expandHome(path string) (string, error) {
	if path != "~" && !strings.HasPrefix(path, "~/") {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("find home directory")
	}
	if path == "~" {
		return home, nil
	}
	return filepath.Join(home, strings.TrimPrefix(path, "~/")), nil
}

func readPrivateFile(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != uint32(os.Geteuid()) || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("credential file must be owner-only")
	}
	return io.ReadAll(file)
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
	registry["github"] = append(registry["github"].(Chain), Executable{Name: "gh", Args: []string{"auth", "token"}})
	registry["anthropicoauth"] = append(registry["anthropicoauth"].(Chain), TextFile{Path: "~/.local/share/cred-forward/secrets/claude-oauth"})
	registry["openaichatgpt"] = append(registry["openaichatgpt"].(Chain), JSONFile{Path: "~/.codex/auth.json", Keys: []string{"tokens", "access_token"}})
	registry["openaiaccount"] = append(registry["openaiaccount"].(Chain), JSONFile{Path: "~/.codex/auth.json", Keys: []string{"tokens", "account_id"}})
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
