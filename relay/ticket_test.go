package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"
)

func testKeys(t *testing.T, raw string) *TicketKeys {
	t.Helper()
	tk, err := ParseTicketKeys(raw)
	if err != nil {
		t.Fatalf("ParseTicketKeys(%q): %v", raw, err)
	}
	return tk
}

func randomKeyHex(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand.Read: %v", err)
	}
	return hex.EncodeToString(b)
}

func TestTicketSealOpenRoundTrip(t *testing.T) {
	tk := testKeys(t, "1:"+randomKeyHex(t))
	deviceToken := []byte{0xde, 0xad, 0xbe, 0xef}
	issuedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	ticket, err := tk.Seal(deviceToken, issuedAt)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	got, gotIssuedAt, err := tk.Open(ticket, 90*24*time.Hour, issuedAt.Add(time.Hour))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if string(got) != string(deviceToken) {
		t.Errorf("device token = %x, want %x", got, deviceToken)
	}
	if !gotIssuedAt.Equal(issuedAt) {
		t.Errorf("issuedAt = %v, want %v", gotIssuedAt, issuedAt)
	}
}

func TestTicketOpenRejectsTamperedCiphertext(t *testing.T) {
	tk := testKeys(t, "1:"+randomKeyHex(t))
	ticket, err := tk.Seal([]byte{0x01, 0x02}, time.Now())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	// Flip a character deep in the base64 body — past the version/key-id prefix, so this
	// exercises AEAD authentication failing, not a short-circuit on the header bytes.
	tampered := []byte(ticket)
	flipAt := len(tampered) - 1
	if tampered[flipAt] == 'A' {
		tampered[flipAt] = 'B'
	} else {
		tampered[flipAt] = 'A'
	}

	if _, _, err := tk.Open(string(tampered), 90*24*time.Hour, time.Now()); !errors.Is(err, ErrInvalidTicket) {
		t.Errorf("Open(tampered) error = %v, want ErrInvalidTicket", err)
	}
}

func TestTicketOpenRejectsExpired(t *testing.T) {
	tk := testKeys(t, "1:"+randomKeyHex(t))
	issuedAt := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)
	ticket, err := tk.Seal([]byte{0x01}, issuedAt)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	ttl := 90 * 24 * time.Hour
	justBeforeExpiry := issuedAt.Add(ttl - time.Minute)
	if _, _, err := tk.Open(ticket, ttl, justBeforeExpiry); err != nil {
		t.Fatalf("Open just before expiry: %v", err)
	}

	justAfterExpiry := issuedAt.Add(ttl + time.Minute)
	if _, _, err := tk.Open(ticket, ttl, justAfterExpiry); !errors.Is(err, ErrTicketExpired) {
		t.Errorf("Open(just after expiry) error = %v, want ErrTicketExpired", err)
	}
}

func TestTicketKeyRotation(t *testing.T) {
	oldKeyHex := randomKeyHex(t)
	newKeyHex := randomKeyHex(t)
	oldKeys := testKeys(t, "1:"+oldKeyHex)
	ticket, err := oldKeys.Seal([]byte{0xaa}, time.Now())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	// A rotation adds a new signing key ahead of the old one. The old key is still listed, so
	// a ticket sealed under it keeps opening.
	rotated := testKeys(t, "2:"+newKeyHex+",1:"+oldKeyHex)
	if _, _, err := rotated.Open(ticket, 90*24*time.Hour, time.Now()); err != nil {
		t.Errorf("Open under rotated keys (old key still present): %v", err)
	}

	// A new ticket sealed after rotation is signed with the new key, id 2, and opens under a
	// config that only knows the new key.
	newTicket, err := rotated.Seal([]byte{0xbb}, time.Now())
	if err != nil {
		t.Fatalf("Seal after rotation: %v", err)
	}
	newKeyOnly := testKeys(t, "2:"+newKeyHex)
	if _, _, err := newKeyOnly.Open(newTicket, 90*24*time.Hour, time.Now()); err != nil {
		t.Errorf("Open(newTicket) under new-key-only config: %v", err)
	}

	// Dropping the old key entirely — the documented way to retire it — makes a ticket sealed
	// under it fail to open, rather than silently still accepted.
	if _, _, err := newKeyOnly.Open(ticket, 90*24*time.Hour, time.Now()); !errors.Is(err, ErrInvalidTicket) {
		t.Errorf("Open(old ticket) after dropping its key = %v, want ErrInvalidTicket", err)
	}
}

func TestTicketIDIsStableAndDependsOnTheWholeTicket(t *testing.T) {
	tk := testKeys(t, "1:"+randomKeyHex(t))
	a, err := tk.Seal([]byte{0x01}, time.Now())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	b, err := tk.Seal([]byte{0x02}, time.Now())
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	if TicketID(a) != TicketID(a) {
		t.Error("TicketID is not stable for the same ticket")
	}
	if TicketID(a) == TicketID(b) {
		t.Error("TicketID collided for two distinct tickets")
	}
	if len(TicketID(a)) != 16 {
		t.Errorf("TicketID length = %d, want 16", len(TicketID(a)))
	}
}

func TestParseTicketKeysRejectsMalformed(t *testing.T) {
	cases := []string{
		"",
		"not-a-valid-entry",
		"1:" + strings.Repeat("a", 63),   // too short
		"1:" + strings.Repeat("a", 65),   // too long
		"1:" + strings.Repeat("zz", 32),  // not hex
		"256:" + strings.Repeat("a", 64), // id out of byte range
		"1:" + strings.Repeat("a", 64) + ",1:" + strings.Repeat("b", 64), // duplicate id
	}
	for _, c := range cases {
		if _, err := ParseTicketKeys(c); err == nil {
			t.Errorf("ParseTicketKeys(%q) = nil error, want an error", c)
		}
	}
}
