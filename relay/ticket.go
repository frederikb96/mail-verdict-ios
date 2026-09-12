package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
)

// ticketVersion is the first byte of every sealed ticket, so a future format change can be
// rejected outright rather than misparsed.
const ticketVersion byte = 0x01

// ticketAAD binds a sealed ticket to this one purpose — without it, a ciphertext produced for
// something else that happened to use the same AES-GCM key would decrypt here too.
const ticketAAD = "mvpr-ticket-v1"

const nonceLen = 12

// ErrInvalidTicket covers every way a ticket fails to open at all: wrong version, unknown
// signing key, or AEAD authentication failure (corrupted, truncated, or forged). These are
// deliberately indistinguishable from each other — nothing here narrows the search for a caller
// probing the endpoint.
var ErrInvalidTicket = errors.New("invalid ticket")

// ErrTicketExpired means the ticket opened and authenticated fine, but its issued_at is older
// than the configured TTL.
var ErrTicketExpired = errors.New("ticket expired")

// Seal encodes an APNs device token into a ticket only the relay's own signing key can produce
// and only a relay holding a matching key can open: version || key_id || nonce ||
// AES-256-GCM(key, nonce, len(token) || token || issued_at_unix, aad). The length prefix exists
// because Apple does not promise device tokens are a fixed size.
func (tk *TicketKeys) Seal(deviceToken []byte, issuedAt time.Time) (string, error) {
	if len(deviceToken) > 255 {
		return "", fmt.Errorf("device token too long to length-prefix in one byte: %d bytes", len(deviceToken))
	}

	plaintext := make([]byte, 0, 1+len(deviceToken)+8)
	plaintext = append(plaintext, byte(len(deviceToken)))
	plaintext = append(plaintext, deviceToken...)
	plaintext = binary.BigEndian.AppendUint64(plaintext, uint64(issuedAt.Unix()))

	key := tk.byID[tk.signingID]
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", fmt.Errorf("building cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", fmt.Errorf("building AEAD: %w", err)
	}

	nonce := make([]byte, nonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("generating nonce: %w", err)
	}

	ciphertext := gcm.Seal(nil, nonce, plaintext, []byte(ticketAAD))

	raw := make([]byte, 0, 2+nonceLen+len(ciphertext))
	raw = append(raw, ticketVersion, tk.signingID)
	raw = append(raw, nonce...)
	raw = append(raw, ciphertext...)

	return base64.RawURLEncoding.EncodeToString(raw), nil
}

// Open recovers the device token and issued-at time sealed into ticket, and checks it against
// ttl. Every configured key is tried by its id byte — a rotation that adds a new signing key
// while this is still running continues to accept tickets sealed under an older one.
func (tk *TicketKeys) Open(ticket string, ttl time.Duration, now time.Time) ([]byte, time.Time, error) {
	raw, err := base64.RawURLEncoding.DecodeString(ticket)
	if err != nil {
		return nil, time.Time{}, ErrInvalidTicket
	}
	// 1 (version) + 1 (key id) + 12 (nonce) + at least 16 (GCM tag, empty plaintext case).
	if len(raw) < 2+nonceLen+16 {
		return nil, time.Time{}, ErrInvalidTicket
	}
	if raw[0] != ticketVersion {
		return nil, time.Time{}, ErrInvalidTicket
	}
	keyID := raw[1]
	nonce := raw[2 : 2+nonceLen]
	ciphertext := raw[2+nonceLen:]

	key, ok := tk.byID[keyID]
	if !ok {
		return nil, time.Time{}, ErrInvalidTicket
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, time.Time{}, ErrInvalidTicket
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, time.Time{}, ErrInvalidTicket
	}

	plaintext, err := gcm.Open(nil, nonce, ciphertext, []byte(ticketAAD))
	if err != nil {
		return nil, time.Time{}, ErrInvalidTicket
	}
	if len(plaintext) < 1 {
		return nil, time.Time{}, ErrInvalidTicket
	}
	tokenLen := int(plaintext[0])
	if len(plaintext) != 1+tokenLen+8 {
		return nil, time.Time{}, ErrInvalidTicket
	}
	deviceToken := plaintext[1 : 1+tokenLen]
	issuedAtUnix := binary.BigEndian.Uint64(plaintext[1+tokenLen:])
	issuedAt := time.Unix(int64(issuedAtUnix), 0).UTC()

	if now.Sub(issuedAt) > ttl {
		return nil, time.Time{}, ErrTicketExpired
	}

	return deviceToken, issuedAt, nil
}

// TicketID is the only per-device identifier that ever appears in logs, metrics or rate-limit
// keys — a stable fingerprint of the ticket string itself, not of anything it encodes. Computed
// the same way regardless of whether the ticket later turns out to be valid, so it exists even
// for a ticket this relay rejects.
func TicketID(ticket string) string {
	sum := sha256.Sum256([]byte(ticket))
	return hex.EncodeToString(sum[:])[:16]
}
