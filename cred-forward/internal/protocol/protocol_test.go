package protocol

import (
	"bufio"
	"bytes"
	"errors"
	"strings"
	"testing"
)

func TestRequestRoundTrip(t *testing.T) {
	for _, service := range []string{
		"github",
		"anthropic",
		"anthropicoauth",
		"openai",
		"openaichatgpt",
		"openaiaccount",
	} {
		var wire bytes.Buffer
		if err := WriteRequest(&wire, service, ""); err != nil {
			t.Fatal(err)
		}
		got, _, err := ReadRequest(bufio.NewReader(&wire))
		if err != nil {
			t.Fatal(err)
		}
		if got != service {
			t.Fatalf("got %q, want %q", got, service)
		}
	}
}

func TestUnknownServiceRequestIsSyntacticallyValid(t *testing.T) {
	service, _, err := ReadRequest(bufio.NewReader(strings.NewReader("CRED/1 GET other\n")))
	if err != nil || service != "other" {
		t.Fatalf("got service %q and error %v", service, err)
	}
}

func TestCredentialRoundTrip(t *testing.T) {
	const want = "token with spaces"
	var wire bytes.Buffer
	if err := WriteCredential(&wire, want); err != nil {
		t.Fatal(err)
	}
	got, remoteCode, err := ReadResponse(bufio.NewReader(&wire))
	if err != nil {
		t.Fatal(err)
	}
	if remoteCode != "" || got != want {
		t.Fatalf("got credential %q and code %q", got, remoteCode)
	}
}

func TestErrorRoundTrip(t *testing.T) {
	var wire bytes.Buffer
	if err := WriteError(&wire, "unavailable"); err != nil {
		t.Fatal(err)
	}
	credential, code, err := ReadResponse(bufio.NewReader(&wire))
	if err != nil {
		t.Fatal(err)
	}
	if credential != "" || code != "unavailable" {
		t.Fatalf("got credential %q and code %q", credential, code)
	}
}

func TestMalformedAndOversizedFramesFail(t *testing.T) {
	tests := []struct {
		name string
		wire string
	}{
		{"bad version", "CRED/2 OK 1\nx"},
		{"bad length", "CRED/1 OK no\n"},
		{"short payload", "CRED/1 OK 2\nx"},
		{"long header", strings.Repeat("x", MaxHeaderSize+1) + "\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, err := ReadResponse(bufio.NewReader(strings.NewReader(test.wire)))
			if !errors.Is(err, ErrInvalidResponse) {
				t.Fatalf("got %v, want ErrInvalidResponse", err)
			}
		})
	}
}

func TestAccountRequestRoundTrip(t *testing.T) {
	var wire bytes.Buffer
	if err := WriteRequest(&wire, "github", "anchi-t2"); err != nil {
		t.Fatal(err)
	}
	if wire.String() != "CRED/1 GET github anchi-t2\n" {
		t.Fatalf("unexpected wire request %q", wire.String())
	}
	service, account, err := ReadRequest(bufio.NewReader(&wire))
	if err != nil {
		t.Fatal(err)
	}
	if service != "github" || account != "anchi-t2" {
		t.Fatalf("got service %q and account %q", service, account)
	}
}

func TestInvalidAccountsAreRejected(t *testing.T) {
	for _, account := range []string{"-leading", "with space", "semi;colon", "dot.name", strings.Repeat("a", MaxAccount+1)} {
		if ValidAccount(account) {
			t.Fatalf("%q unexpectedly valid", account)
		}
		if err := WriteRequest(&bytes.Buffer{}, "github", account); !errors.Is(err, ErrInvalidRequest) {
			t.Fatalf("%q: got %v, want ErrInvalidRequest", account, err)
		}
	}
	for _, wire := range []string{"CRED/1 GET github -bad\n", "CRED/1 GET github a b\n", "CRED/1 GET github \n"} {
		if _, _, err := ReadRequest(bufio.NewReader(strings.NewReader(wire))); !errors.Is(err, ErrInvalidRequest) {
			t.Fatalf("%q: got %v, want ErrInvalidRequest", wire, err)
		}
	}
	if !ValidAccount("tigercosmos") || !ValidAccount("anchi-t2") || !ValidAccount("A1") {
		t.Fatal("valid GitHub logins were rejected")
	}
}
