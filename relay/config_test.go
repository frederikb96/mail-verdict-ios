package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setConfigEnv sets every env var LoadConfig requires to a valid value and returns a cleanup
// that restores the environment, so tests can override exactly the one variable they're
// checking without hand-maintaining the whole set in every test.
func setConfigEnv(t *testing.T, keyPath string) {
	t.Helper()
	vars := map[string]string{
		"APNS_KEY_ID":        "ABC123",
		"APNS_TEAM_ID":       "TEAM123",
		"APNS_TOPIC":         "com.example.app",
		"APNS_AUTH_KEY_PATH": keyPath,
		"TICKET_KEYS":        "1:" + strings.Repeat("ab", 32),
	}
	for k, v := range vars {
		t.Setenv(k, v)
	}
}

func TestLoadConfigRequiresEveryMandatoryValue(t *testing.T) {
	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "AuthKey.p8")
	if err := os.WriteFile(keyPath, []byte("not a real key, just a readable file"), 0o600); err != nil {
		t.Fatalf("writing fake key file: %v", err)
	}

	required := []string{"APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC", "APNS_AUTH_KEY_PATH", "TICKET_KEYS"}
	for _, missing := range required {
		t.Run(missing, func(t *testing.T) {
			setConfigEnv(t, keyPath)
			t.Setenv(missing, "")
			if _, err := LoadConfig(); err == nil {
				t.Errorf("LoadConfig() with %s unset = nil error, want an error", missing)
			}
		})
	}
}

func TestLoadConfigRejectsAnUnreadableAuthKeyPath(t *testing.T) {
	setConfigEnv(t, "/nonexistent/path/AuthKey.p8")
	if _, err := LoadConfig(); err == nil {
		t.Error("LoadConfig() with an unreadable APNS_AUTH_KEY_PATH = nil error, want an error")
	}
}

func TestLoadConfigAppliesDefaults(t *testing.T) {
	tmp := t.TempDir()
	keyPath := filepath.Join(tmp, "AuthKey.p8")
	if err := os.WriteFile(keyPath, []byte("fake"), 0o600); err != nil {
		t.Fatalf("writing fake key file: %v", err)
	}
	setConfigEnv(t, keyPath)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}

	if cfg.TicketTTLDays != 90 {
		t.Errorf("TicketTTLDays default = %d, want 90", cfg.TicketTTLDays)
	}
	if cfg.RateLimits.AlertPerTicketPerHour != 60 || cfg.RateLimits.AlertPerTicketBurst != 30 {
		t.Errorf("alert-per-ticket defaults = %d/%d, want 60/30", cfg.RateLimits.AlertPerTicketPerHour, cfg.RateLimits.AlertPerTicketBurst)
	}
	if cfg.RateLimits.BackgroundPerTicketBurst != cfg.RateLimits.BackgroundPerTicketPerHour {
		t.Error("background burst should default to the hourly rate itself")
	}
	if cfg.ListenAddr != ":8080" {
		t.Errorf("ListenAddr default = %q, want %q", cfg.ListenAddr, ":8080")
	}
	if cfg.FallbackAlertTitle != "MailVerdict" {
		t.Errorf("FallbackAlertTitle default = %q, want %q", cfg.FallbackAlertTitle, "MailVerdict")
	}
}
