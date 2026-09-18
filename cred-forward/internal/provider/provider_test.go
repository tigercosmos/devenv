package provider

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
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
	_, err := registry.Credential(context.Background(), "github", "")
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

func TestExecutableDoesNotInvokeShell(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "credential helper")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nprintf credential\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	got, err := (Executable{Name: path}).Credential(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got != "credential" {
		t.Fatalf("got %q", got)
	}
}

func TestTextFileRequiresOwnerOnlyPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "credential")
	if err := os.WriteFile(path, []byte("credential\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := (TextFile{Path: path}).Credential(context.Background())
	if err == nil {
		t.Fatal("world-readable credential file unexpectedly succeeded")
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := (TextFile{Path: path}).Credential(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got != "credential" {
		t.Fatalf("got %q", got)
	}
}

func TestJSONFileReadsNestedCredential(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth.json")
	if err := os.WriteFile(path, []byte(`{"tokens":{"access_token":"credential"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := (JSONFile{Path: path, Keys: []string{"tokens", "access_token"}}).Credential(context.Background())
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
			got, err := NewDefaultRegistry().Credential(context.Background(), service, "")
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
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PATH", "")
	t.Setenv("CRED_AGENT_INHERIT_ENV", "")
	t.Setenv("CRED_AGENT_GITHUB", "")
	t.Setenv("CRED_AGENT_GITHUB_COMMAND", "")
	t.Setenv("GH_TOKEN", "ambient-credential")
	_, err := NewDefaultRegistry().Credential(context.Background(), "github", "")
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("got %v, want ErrNotConfigured", err)
	}
}

func TestDefaultRegistryCanExplicitlyInheritStandardVariables(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PATH", "")
	t.Setenv("CRED_AGENT_INHERIT_ENV", "1")
	t.Setenv("CRED_AGENT_GITHUB", "")
	t.Setenv("CRED_AGENT_GITHUB_COMMAND", "")
	t.Setenv("GH_TOKEN", "ambient-credential")
	got, err := NewDefaultRegistry().Credential(context.Background(), "github", "")
	if err != nil {
		t.Fatal(err)
	}
	if got != "ambient-credential" {
		t.Fatalf("got %q", got)
	}
}

func TestDefaultRegistryUsesLocalLoginCredentials(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	gh := filepath.Join(bin, "gh")
	if err := os.WriteFile(gh, []byte("#!/bin/sh\nprintf github-login\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	codexDir := filepath.Join(home, ".codex")
	if err := os.MkdirAll(codexDir, 0o700); err != nil {
		t.Fatal(err)
	}
	auth := `{"tokens":{"access_token":"chatgpt-login","account_id":"account-id"}}`
	if err := os.WriteFile(filepath.Join(codexDir, "auth.json"), []byte(auth), 0o600); err != nil {
		t.Fatal(err)
	}
	secretDir := filepath.Join(home, ".local", "share", "cred-forward", "secrets")
	if err := os.MkdirAll(secretDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(secretDir, "claude-oauth"), []byte("claude-login\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("PATH", bin)

	tests := map[string]string{
		"github":         "github-login",
		"anthropicoauth": "claude-login",
		"openaichatgpt":  "chatgpt-login",
		"openaiaccount":  "account-id",
	}
	for service, want := range tests {
		got, err := NewDefaultRegistry().Credential(context.Background(), service, "")
		if err != nil {
			t.Fatalf("%s: %v", service, err)
		}
		if got != want {
			t.Fatalf("%s: got %q, want %q", service, got, want)
		}
	}
}

func TestDefaultRegistryServesNamedGitHubAccounts(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	// The fake gh echoes the requested user so the test can see the arguments.
	script := "#!/bin/sh\nif [ \"$3 $4 $5\" = '--hostname github.com --user' ]; then printf 'login-for-%s' \"$6\"; else printf active-login; fi\n"
	if err := os.WriteFile(filepath.Join(bin, "gh"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("PATH", bin)
	t.Setenv("CRED_AGENT_GITHUB", "")
	t.Setenv("CRED_AGENT_GITHUB_COMMAND", "")

	registry := NewDefaultRegistry()
	got, err := registry.Credential(context.Background(), "github", "")
	if err != nil || got != "active-login" {
		t.Fatalf("default login: got %q, %v", got, err)
	}
	got, err = registry.Credential(context.Background(), "github", "anchi-t2")
	if err != nil || got != "login-for-anchi-t2" {
		t.Fatalf("named login: got %q, %v", got, err)
	}

	t.Setenv("CRED_AGENT_GITHUB_TOKEN_ANCHI_T2", "env-login")
	got, err = registry.Credential(context.Background(), "github", "anchi-t2")
	if err != nil || got != "env-login" {
		t.Fatalf("env override: got %q, %v", got, err)
	}
	t.Setenv("CRED_AGENT_GITHUB_COMMAND_ALICE", "printf command-login")
	got, err = registry.Credential(context.Background(), "github", "alice")
	if err != nil || got != "command-login" {
		t.Fatalf("command override: got %q, %v", got, err)
	}
	// An account whose name ends in "command" must not read alice's helper.
	got, err = registry.Credential(context.Background(), "github", "alice-command")
	if err != nil || got != "login-for-alice-command" {
		t.Fatalf("namespace collision: got %q, %v", got, err)
	}
	if got, err := registry.Credential(context.Background(), "github", "tigercosmos"); err != nil || got != "login-for-tigercosmos" {
		t.Fatalf("other account: got %q, %v", got, err)
	}

	if _, err := registry.Credential(context.Background(), "anthropic", "anchi-t2"); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("account on a single-login service: got %v, want ErrNotConfigured", err)
	}
	if _, err := registry.Credential(context.Background(), "github", "bad name"); !errors.Is(err, ErrInvalidValue) {
		t.Fatalf("invalid account: got %v, want ErrInvalidValue", err)
	}
}

// countingSource blocks every lookup on release so a burst is provably
// concurrent, and counts how many lookups ran.
type countingSource struct {
	calls   atomic.Int64
	release chan struct{}
	err     error
}

func (c *countingSource) Credential(context.Context) (string, error) {
	c.calls.Add(1)
	<-c.release
	return "credential", c.err
}

func TestCachedSharesOneLookupAcrossBurst(t *testing.T) {
	source := &countingSource{release: make(chan struct{})}
	now := time.Unix(1000, 0)
	cached := &Cached{Source: source, TTL: time.Minute, Now: func() time.Time { return now }}

	results := make(chan string, 8)
	for i := 0; i < 8; i++ {
		go func() {
			got, err := cached.Credential(context.Background())
			if err != nil {
				t.Error(err)
			}
			results <- got
		}()
	}
	// Every caller has either started the lookup or is waiting on it before
	// the lookup is allowed to finish.
	for source.calls.Load() == 0 {
		time.Sleep(time.Millisecond)
	}
	close(source.release)
	for i := 0; i < 8; i++ {
		if got := <-results; got != "credential" {
			t.Fatalf("got %q", got)
		}
	}
	if calls := source.calls.Load(); calls != 1 {
		t.Fatalf("source ran %d times during the burst, want 1", calls)
	}

	now = now.Add(2 * time.Minute)
	if _, err := cached.Credential(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls := source.calls.Load(); calls != 2 {
		t.Fatalf("source ran %d times after expiry, want 2", calls)
	}
}

func TestCachedSharesFailureAcrossBurstWithoutKeepingIt(t *testing.T) {
	source := &countingSource{release: make(chan struct{}), err: errors.New("gh is broken")}
	cached := &Cached{Source: source, TTL: time.Minute}
	errs := make(chan error, 4)
	for i := 0; i < 4; i++ {
		go func() {
			_, err := cached.Credential(context.Background())
			errs <- err
		}()
	}
	for source.calls.Load() == 0 {
		time.Sleep(time.Millisecond)
	}
	close(source.release)
	for i := 0; i < 4; i++ {
		if err := <-errs; err == nil || err.Error() != "gh is broken" {
			t.Fatalf("got %v", err)
		}
	}
	if calls := source.calls.Load(); calls != 1 {
		t.Fatalf("a failing burst ran the source %d times, want 1", calls)
	}
	source.err = nil
	if got, err := cached.Credential(context.Background()); err != nil || got != "credential" {
		t.Fatalf("after failure: got %q, %v", got, err)
	}
}

func TestCachedDoesNotCacheErrors(t *testing.T) {
	failing := &Cached{Source: Env{Name: "CF_UNSET", Lookup: func(string) (string, bool) { return "", false }}, TTL: time.Minute}
	for i := 0; i < 2; i++ {
		if _, err := failing.Credential(context.Background()); !errors.Is(err, ErrNotConfigured) {
			t.Fatalf("got %v", err)
		}
	}
}

func TestDefaultRegistryCachesGitHubLoginsPerAccount(t *testing.T) {
	home := t.TempDir()
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	gh := filepath.Join(bin, "gh")
	// PATH holds only the fake gh, so the script uses shell builtins alone.
	script := "#!/bin/sh\nprintf x >>" + filepath.Join(home, "calls") + "\nprintf '%s' \"$*\"\n"
	if err := os.WriteFile(gh, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("PATH", bin)
	t.Setenv("CRED_AGENT_GITHUB", "")
	t.Setenv("CRED_AGENT_GITHUB_COMMAND", "")
	registry := NewDefaultRegistry()
	for i := 0; i < 3; i++ {
		for _, account := range []string{"", "anchi-t2"} {
			got, err := registry.Credential(context.Background(), "github", account)
			if err != nil {
				t.Fatal(err)
			}
			want := "auth token"
			if account != "" {
				want = "auth token --hostname github.com --user " + account
			}
			if got != want {
				t.Fatalf("account %q: got %q, want %q", account, got, want)
			}
		}
	}
	if calls, _ := os.ReadFile(filepath.Join(home, "calls")); len(calls) != 2 {
		t.Fatalf("gh ran %d times, want once per account", len(calls))
	}
}
