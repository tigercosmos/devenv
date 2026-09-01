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
		if err := WriteRequest(&wire, service); err != nil {
			t.Fatal(err)
		}
		got, err := ReadRequest(bufio.NewReader(&wire))
		if err != nil {
			t.Fatal(err)
		}
		if got != service {
			t.Fatalf("got %q, want %q", got, service)
		}
	}
}

func TestUnknownServiceRequestIsSyntacticallyValid(t *testing.T) {
	service, err := ReadRequest(bufio.NewReader(strings.NewReader("CRED/1 GET other\n")))
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
