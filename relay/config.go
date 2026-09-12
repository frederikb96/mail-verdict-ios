package main

import (
	"encoding/hex"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is the whole configuration surface of this service: APNs identity, the ticket signing
// keys, rate-limit knobs and the fixed fallback banner text. Every value without a default below
// must be set, or the process refuses to start — a relay silently running with a guessed APNs
// topic sends pushes Apple rejects for a reason nobody sees until a phone stops getting them.
type Config struct {
	// APNs identity. None of these are secret — the .p8 key file is the one value that is.
	APNSKeyID  string
	APNSTeamID string
	// APNSTopic is the app bundle id every registered device belongs to. APNs rejects a push
	// whose topic does not match the token's own app, so a wrong value here fails loud
	// (DeviceTokenNotForTopic) rather than silently reaching no one.
	APNSTopic       string
	APNSAuthKeyPath string

	// TicketKeys seals and opens push tickets. The first configured key is the one new tickets
	// are sealed with; every configured key is tried when opening one, so a rotation can add a
	// new signing key while still accepting tickets sealed under the old one.
	TicketKeys *TicketKeys
	// TicketTTL is how long a sealed ticket stays valid from the moment it was issued.
	TicketTTLDays int

	// FallbackAlertTitle/Body are what APNs actually shows before the phone's own notification
	// extension decrypts the real banner — fixed relay configuration, never caller-supplied,
	// since the relay never knows what an alert is actually about.
	FallbackAlertTitle string
	FallbackAlertBody  string

	RateLimits RateLimitConfig

	// MaxBodyBytes bounds the whole request body. MaxBlobChars bounds the blob field
	// specifically, since a request can be under the body cap and still carry an oversized blob.
	MaxBodyBytes int64
	MaxBlobChars int

	ListenAddr string
}

// RateLimitConfig holds the per-scope token-bucket parameters described in README.md's rate
// limit table. Burst is configurable per bucket because the alert-per-ticket bucket deliberately
// allows fewer than a full hour's worth at once (60/hour, burst 30); buckets with no such
// distinction default burst to the hourly rate itself, i.e. "a full hour of budget up front."
type RateLimitConfig struct {
	AlertPerTicketPerHour int
	AlertPerTicketBurst   int
	AlertPerTicketPerDay  int

	BackgroundPerTicketPerHour int
	BackgroundPerTicketBurst   int

	IPPushesPerHour int
	IPPushesBurst   int

	IPRegistrationsPerHour int
	IPRegistrationsBurst   int
}

func requireEnv(name string) (string, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return "", fmt.Errorf("%s is required and must not be empty", name)
	}
	return v, nil
}

func envOrDefault(name, def string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return def
}

func envIntOrDefault(name string, def int) (int, error) {
	raw := envOrDefault(name, strconv.Itoa(def))
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer, got %q: %w", name, raw, err)
	}
	return n, nil
}

// LoadConfig reads and validates the whole configuration surface in one place, so main either
// has a Config it can trust completely or an error naming exactly what is missing.
func LoadConfig() (Config, error) {
	var cfg Config
	var err error

	if cfg.APNSKeyID, err = requireEnv("APNS_KEY_ID"); err != nil {
		return Config{}, err
	}
	if cfg.APNSTeamID, err = requireEnv("APNS_TEAM_ID"); err != nil {
		return Config{}, err
	}
	if cfg.APNSTopic, err = requireEnv("APNS_TOPIC"); err != nil {
		return Config{}, err
	}
	if cfg.APNSAuthKeyPath, err = requireEnv("APNS_AUTH_KEY_PATH"); err != nil {
		return Config{}, err
	}
	if _, statErr := os.Stat(cfg.APNSAuthKeyPath); statErr != nil {
		return Config{}, fmt.Errorf("APNS_AUTH_KEY_PATH %q is not readable: %w", cfg.APNSAuthKeyPath, statErr)
	}

	ticketKeysRaw, err := requireEnv("TICKET_KEYS")
	if err != nil {
		return Config{}, err
	}
	if cfg.TicketKeys, err = ParseTicketKeys(ticketKeysRaw); err != nil {
		return Config{}, fmt.Errorf("TICKET_KEYS: %w", err)
	}

	if cfg.TicketTTLDays, err = envIntOrDefault("TICKET_TTL_DAYS", 90); err != nil {
		return Config{}, err
	}
	if cfg.TicketTTLDays <= 0 {
		return Config{}, fmt.Errorf("TICKET_TTL_DAYS must be positive, got %d", cfg.TicketTTLDays)
	}

	cfg.FallbackAlertTitle = envOrDefault("FALLBACK_ALERT_TITLE", "MailVerdict")
	cfg.FallbackAlertBody = envOrDefault("FALLBACK_ALERT_BODY", "New notification")

	rl := &cfg.RateLimits
	for _, f := range []struct {
		name string
		def  int
		dst  *int
	}{
		{"RATE_ALERT_PER_TICKET_PER_HOUR", 60, &rl.AlertPerTicketPerHour},
		{"RATE_ALERT_PER_TICKET_BURST", 30, &rl.AlertPerTicketBurst},
		{"RATE_ALERT_PER_TICKET_PER_DAY", 500, &rl.AlertPerTicketPerDay},
		{"RATE_BACKGROUND_PER_TICKET_PER_HOUR", 12, &rl.BackgroundPerTicketPerHour},
		{"RATE_IP_PUSHES_PER_HOUR", 1200, &rl.IPPushesPerHour},
		{"RATE_IP_REGISTRATIONS_PER_HOUR", 30, &rl.IPRegistrationsPerHour},
	} {
		v, err := envIntOrDefault(f.name, f.def)
		if err != nil {
			return Config{}, err
		}
		if v <= 0 {
			return Config{}, fmt.Errorf("%s must be positive, got %d", f.name, v)
		}
		*f.dst = v
	}
	// Bursts with no distinct default fall back to the hourly rate itself.
	rl.BackgroundPerTicketBurst = rl.BackgroundPerTicketPerHour
	rl.IPPushesBurst = rl.IPPushesPerHour
	rl.IPRegistrationsBurst = rl.IPRegistrationsPerHour

	if cfg.MaxBodyBytes, err = envInt64OrDefault("MAX_BODY_BYTES", 8192); err != nil {
		return Config{}, err
	}
	if cfg.MaxBlobChars, err = envIntOrDefault("MAX_BLOB_CHARS", 3072); err != nil {
		return Config{}, err
	}

	cfg.ListenAddr = envOrDefault("LISTEN_ADDR", ":8080")

	return cfg, nil
}

func envInt64OrDefault(name string, def int64) (int64, error) {
	raw := envOrDefault(name, strconv.FormatInt(def, 10))
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer, got %q: %w", name, raw, err)
	}
	return n, nil
}

// ticketKeyHexLen is 64 hex characters — a 32-byte (AES-256) key.
const ticketKeyHexLen = 64

// TicketKeys holds every configured ticket-sealing key, keyed by its single-byte id, plus which
// one is current. See ParseTicketKeys for the TICKET_KEYS env var format.
type TicketKeys struct {
	signingID byte
	byID      map[byte][]byte
}

// ParseTicketKeys parses "TICKET_KEYS=<id>:<64 hex>,<id>:<64 hex>,...". The first entry is the
// signing key new tickets are sealed with; every entry is tried when opening one. Dropping an
// old entry on the next deploy is how a key is retired — tickets sealed under it then fail to
// open (401 InvalidTicket), and the app re-registers.
func ParseTicketKeys(raw string) (*TicketKeys, error) {
	entries := strings.Split(raw, ",")
	tk := &TicketKeys{byID: make(map[byte][]byte, len(entries))}
	for i, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			return nil, fmt.Errorf("empty entry")
		}
		parts := strings.SplitN(entry, ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("entry %q is not \"<id>:<64 hex>\"", entry)
		}
		idNum, err := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err != nil || idNum < 0 || idNum > 255 {
			return nil, fmt.Errorf("entry %q: key id must be 0-255", entry)
		}
		id := byte(idNum)
		keyHex := strings.TrimSpace(parts[1])
		if len(keyHex) != ticketKeyHexLen {
			return nil, fmt.Errorf("entry %q: key must be %d hex characters (32 bytes), got %d", entry, ticketKeyHexLen, len(keyHex))
		}
		key, err := hex.DecodeString(keyHex)
		if err != nil {
			return nil, fmt.Errorf("entry %q: key is not valid hex: %w", entry, err)
		}
		if _, exists := tk.byID[id]; exists {
			return nil, fmt.Errorf("duplicate key id %d", id)
		}
		tk.byID[id] = key
		if i == 0 {
			tk.signingID = id
		}
	}
	if len(tk.byID) == 0 {
		return nil, fmt.Errorf("no keys configured")
	}
	return tk, nil
}
