package provider

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tigercosmos/devenv/cred-forward/internal/protocol"
)

func TestChainUsesFirstConfiguredSource(t *testing.T) {
	values := map[string]string{"SECOND": "wanted"}
	lookup := func(name string) (string, bool) {
		value, ok := values[name]
		return value, ok
	}
	chain := Chain{Env{Name: "FIRST", Lookup: lookup}, Env{Name: "SECOND", Lookup: lookup}}
	got, err := chain.Credential(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got != "wanted" {
		t.Fatalf("got %q", got)
	}
}

func TestRegistryRejectsMultilineCredential(t *testing.T) {
	registry := Registry{"github": Env{Name: "TOKEN", Lookup: func(string) (string, bool) {
		return "secret\nsecond-line", true
	}}}
	_, err := registry.Credential(context.Background(), "github")
	if !errors.Is(err, ErrInvalidValue) {
		t.Fatalf("got %v, want ErrInvalidValue", err)
	}
}

func TestCommandDoesNotExposeOutputInError(t *testing.T) {
	const secret = "must-not-leak"
	command := Command{
		EnvName: "COMMAND",
		Lookup: func(string) (string, bool) {
			return "printf '" + secret + "'; exit 1", true
		},
		Timeout: time.Second,
	}
	_, err := command.Credential(context.Background())
	if err == nil || strings.Contains(err.Error(), secret) {
		t.Fatalf("unsafe error: %v", err)
	}
}

func TestCommandDoesNotInheritCredentialEnvironment(t *testing.T) {
	t.Setenv("CRED_AGENT_OPENAI", "must-not-leak")
	t.Setenv("OPENAI_API_KEY", "must-not-leak")
	command := Command{
		EnvName: "COMMAND",
		Lookup: func(string) (string, bool) {
			return `test -n "$HOME"; test -z "${CRED_AGENT_OPENAI:-}"; test -z "${OPENAI_API_KEY:-}"; printf credential`, true
		},
	}
	got, err := command.Credential(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got != "credential" {
		t.Fatalf("got %q", got)
	}
}

func TestCommandTimeoutKillsDescendantsHoldingStdout(t *testing.T) {
	command := Command{
		EnvName: "COMMAND",
		Lookup: func(string) (string, bool) {
			return `(sleep 30) & wait`, true
		},
		Timeout: 100 * time.Millisecond,
	}
	started := time.Now()
	_, err := command.Credential(context.Background())
	if err == nil {
		t.Fatal("timed-out command unexpectedly succeeded")
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("timed-out command took %s", elapsed)
	}
}

func TestCommandOversizeKillsDescendants(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "descendant-survived")
	command := Command{
		EnvName: "COMMAND",
		Lookup: func(string) (string, bool) {
			return "(sleep 0.5; touch '" + marker + "') & head -c 70000 /dev/zero", true
		},
	}
	_, err := command.Credential(context.Background())
	if !errors.Is(err, protocol.ErrCredentialTooLarge) {
		t.Fatalf("got %v, want ErrCredentialTooLarge", err)
	}
	time.Sleep(750 * time.Millisecond)
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("credential command descendant survived: %v", err)
	}
}

func TestDefaultRegistrySupportsLoginCredentialKinds(t *testing.T) {
	tests := map[string]string{
		"github":         "CRED_AGENT_GITHUB",
		"anthropic":      "CRED_AGENT_ANTHROPIC",
		"anthropicoauth": "CRED_AGENT_ANTHROPIC_OAUTH",
		"openai":         "CRED_AGENT_OPENAI",
		"openaichatgpt":  "CRED_AGENT_OPENAI_CHATGPT",
		"openaiaccount":  "CRED_AGENT_OPENAI_ACCOUNT",
	}
	for service, envName := range tests {
		t.Run(service, func(t *testing.T) {
			t.Setenv(envName, "credential")
			got, err := NewDefaultRegistry().Credential(context.Background(), service)
			if err != nil {
				t.Fatal(err)
			}
			if got != "credential" {
				t.Fatalf("got %q", got)
			}
		})
	}
}

func TestDefaultRegistryDoesNotInheritStandardVariablesByDefault(t *testing.T) {
	t.Setenv("CRED_AGENT_INHERIT_ENV", "")
	t.Setenv("CRED_AGENT_GITHUB", "")
	t.Setenv("CRED_AGENT_GITHUB_COMMAND", "")
	t.Setenv("GH_TOKEN", "ambient-credential")
	_, err := NewDefaultRegistry().Credential(context.Background(), "github")
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("got %v, want ErrNotConfigured", err)
	}
}

func TestDefaultRegistryCanExplicitlyInheritStandardVariables(t *testing.T) {
	t.Setenv("CRED_AGENT_INHERIT_ENV", "1")
	t.Setenv("CRED_AGENT_GITHUB", "")
	t.Setenv("CRED_AGENT_GITHUB_COMMAND", "")
	t.Setenv("GH_TOKEN", "ambient-credential")
	got, err := NewDefaultRegistry().Credential(context.Background(), "github")
	if err != nil {
		t.Fatal(err)
	}
	if got != "ambient-credential" {
		t.Fatalf("got %q", got)
	}
}
