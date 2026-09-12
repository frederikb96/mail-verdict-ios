package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// fakePusher lets a handler test script exactly one APNs outcome without a network call.
type fakePusher struct {
	outcome PushOutcome
	calls   int
	lastReq PushRequest
}

func (f *fakePusher) Push(_ context.Context, req PushRequest) PushOutcome {
	f.calls++
	f.lastReq = req
	return f.outcome
}

func testServer(t *testing.T, pusher Pusher, rl RateLimitConfig) (*Server, *TicketKeys) {
	t.Helper()
	tk := testKeys(t, "1:"+randomKeyHex(t))
	discard := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := NewServer(tk, 90*24*time.Hour, pusher, NewRateLimiters(rl), NewMetrics(), discard, 8192, 3072)
	return server, tk
}

func generousRateLimits() RateLimitConfig {
	return RateLimitConfig{
		AlertPerTicketPerHour: 1000, AlertPerTicketBurst: 1000, AlertPerTicketPerDay: 1000,
		BackgroundPerTicketPerHour: 1000, BackgroundPerTicketBurst: 1000,
		IPPushesPerHour: 1000, IPPushesBurst: 1000,
		IPRegistrationsPerHour: 1000, IPRegistrationsBurst: 1000,
	}
}

func doJSON(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal request body: %v", err)
		}
		reader = bytes.NewReader(b)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decodeBody[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("decode response body %q: %v", rec.Body.String(), err)
	}
	return v
}

func TestRegisterHappyPath(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())

	rec := doJSON(t, server.Handler(), "POST", "/v1/register", registerRequest{ApnsToken: strings.Repeat("ab", 32)})
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	resp := decodeBody[registerResponse](t, rec)
	if resp.Ticket == "" || resp.TicketID == "" || resp.ExpiresAt == "" {
		t.Errorf("incomplete response: %+v", resp)
	}
	if resp.TicketID != TicketID(resp.Ticket) {
		t.Errorf("ticket_id in response does not match TicketID(ticket)")
	}
}

func TestRegisterRejectsBadToken(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())

	cases := []string{
		"",
		"tooshort",
		strings.Repeat("g", 32),   // not hex
		strings.Repeat("a", 15),   // below minimum, odd length too
		strings.Repeat("ab", 101), // 202 chars, over maximum
		strings.Repeat("a", 17),   // odd length
	}
	for _, tok := range cases {
		rec := doJSON(t, server.Handler(), "POST", "/v1/register", registerRequest{ApnsToken: tok})
		if rec.Code != http.StatusBadRequest {
			t.Errorf("apns_token=%q: status = %d, want 400", tok, rec.Code)
		}
	}
}

func TestRegisterIsRateLimitedPerIP(t *testing.T) {
	rl := generousRateLimits()
	rl.IPRegistrationsPerHour = 1
	rl.IPRegistrationsBurst = 1
	server, _ := testServer(t, &fakePusher{}, rl)

	first := doJSON(t, server.Handler(), "POST", "/v1/register", registerRequest{ApnsToken: strings.Repeat("ab", 32)})
	if first.Code != http.StatusOK {
		t.Fatalf("first registration: status = %d, body = %s", first.Code, first.Body.String())
	}

	second := doJSON(t, server.Handler(), "POST", "/v1/register", registerRequest{ApnsToken: strings.Repeat("cd", 32)})
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second registration: status = %d, want 429", second.Code)
	}
	body := decodeBody[retryAfterResponse](t, second)
	if body.RetryAfterSeconds <= 0 {
		t.Errorf("retry_after_seconds = %d, want > 0", body.RetryAfterSeconds)
	}
}

func registerAndGetTicket(t *testing.T, h http.Handler) string {
	t.Helper()
	rec := doJSON(t, h, "POST", "/v1/register", registerRequest{ApnsToken: strings.Repeat("ab", 32)})
	if rec.Code != http.StatusOK {
		t.Fatalf("register: status = %d, body = %s", rec.Code, rec.Body.String())
	}
	return decodeBody[registerResponse](t, rec).Ticket
}

func TestPushAlertHappyPath(t *testing.T) {
	pusher := &fakePusher{outcome: PushOutcome{Status: 202, ApnsID: "apns-id-123"}}
	server, _ := testServer(t, pusher, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: ticket, Type: "alert", Blob: "YWJjZA==", CollapseID: "collapse-1", TTLSeconds: 300,
	})
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	resp := decodeBody[pushResponse](t, rec)
	if resp.ApnsID != "apns-id-123" {
		t.Errorf("apns_id = %q, want %q", resp.ApnsID, "apns-id-123")
	}
	if pusher.calls != 1 {
		t.Errorf("pusher called %d times, want 1", pusher.calls)
	}
	if pusher.lastReq.Kind != "alert" || pusher.lastReq.Blob != "YWJjZA==" {
		t.Errorf("pusher received %+v, want the alert request forwarded unchanged", pusher.lastReq)
	}
}

func TestPushBackgroundRejectsBlob(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: ticket, Type: "background", Blob: "YWJjZA==",
	})
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 (background push must not carry a blob)", rec.Code)
	}
}

func TestPushAlertRequiresBlob(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "alert"})
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 (alert push without a blob)", rec.Code)
	}
}

func TestPushRejectsOversizedBlob(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: ticket, Type: "alert", Blob: strings.Repeat("A", 3073),
	})
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("status = %d, want 413", rec.Code)
	}
}

func TestPushRejectsOtherMalformedFields(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	cases := []struct {
		name string
		req  pushRequest
	}{
		{"ticket missing", pushRequest{Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60}},
		{"type unrecognized", pushRequest{Ticket: ticket, Type: "silent", Blob: "YWJjZA==", TTLSeconds: 60}},
		{"blob not valid base64", pushRequest{Ticket: ticket, Type: "alert", Blob: "not base64!!", TTLSeconds: 60}},
		{"collapse_id over 64 bytes", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", CollapseID: strings.Repeat("x", 65), TTLSeconds: 60}},
		{"ttl_seconds negative", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: -1}},
		{"ttl_seconds over 86400", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 86401}},
	}
	for _, c := range cases {
		rec := doJSON(t, server.Handler(), "POST", "/v1/push", c.req)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", c.name, rec.Code)
		}
	}
}

func TestPushRejectsOversizedBody(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	// A collapse_id alone, padded past the server's 8 KB body cap — the cap trips on the raw
	// body size before field-level validation (which would reject this collapse_id anyway)
	// ever runs, which is the behaviour under test.
	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: ticket, Type: "alert", Blob: "YWJjZA==", CollapseID: strings.Repeat("x", 8200),
	})
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("status = %d, want 413", rec.Code)
	}
}

func TestPushRejectsInvalidTicket(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: "not-a-real-ticket", Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60,
	})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	body := decodeBody[reasonResponse](t, rec)
	if body.Reason != "InvalidTicket" {
		t.Errorf("reason = %q, want %q", body.Reason, "InvalidTicket")
	}
}

func TestPushRejectsExpiredTicket(t *testing.T) {
	discard := slog.New(slog.NewTextHandler(io.Discard, nil))
	tk := testKeys(t, "1:"+randomKeyHex(t))
	server := NewServer(tk, time.Hour, &fakePusher{}, NewRateLimiters(generousRateLimits()), NewMetrics(), discard, 8192, 3072)

	oldTicket, err := tk.Seal([]byte{0x01, 0x02}, time.Now().Add(-2*time.Hour))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: oldTicket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60,
	})
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	body := decodeBody[reasonResponse](t, rec)
	if body.Reason != "TicketExpired" {
		t.Errorf("reason = %q, want %q", body.Reason, "TicketExpired")
	}
}

func TestPushGoneDeletesNothingButReportsReason(t *testing.T) {
	pusher := &fakePusher{outcome: PushOutcome{Status: 410, Reason: "Unregistered"}}
	server, _ := testServer(t, pusher, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60,
	})
	if rec.Code != http.StatusGone {
		t.Fatalf("status = %d, body = %s", rec.Code, rec.Body.String())
	}
	body := decodeBody[reasonResponse](t, rec)
	if body.Reason != "Unregistered" {
		t.Errorf("reason = %q, want %q", body.Reason, "Unregistered")
	}
}

func TestPushUpstreamFailureBecomes502(t *testing.T) {
	pusher := &fakePusher{outcome: PushOutcome{Status: 502, Reason: "boom"}}
	server, _ := testServer(t, pusher, generousRateLimits())
	ticket := registerAndGetTicket(t, server.Handler())

	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{
		Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60,
	})
	if rec.Code != http.StatusBadGateway {
		t.Errorf("status = %d, want 502", rec.Code)
	}
}

func TestPushAlertIsRateLimitedPerTicketBeforeReachingThePusher(t *testing.T) {
	rl := generousRateLimits()
	rl.AlertPerTicketPerHour = 1
	rl.AlertPerTicketBurst = 1
	pusher := &fakePusher{outcome: PushOutcome{Status: 202, ApnsID: "x"}}
	server, _ := testServer(t, pusher, rl)
	ticket := registerAndGetTicket(t, server.Handler())

	first := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60})
	if first.Code != http.StatusAccepted {
		t.Fatalf("first push: status = %d, body = %s", first.Code, first.Body.String())
	}

	second := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60})
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second push: status = %d, want 429", second.Code)
	}
	if pusher.calls != 1 {
		t.Errorf("pusher called %d times, want exactly 1 — the rate limit must trip before the pusher is reached", pusher.calls)
	}
}

func TestPushBackgroundBucketIsSeparateFromAlertBucket(t *testing.T) {
	rl := generousRateLimits()
	rl.AlertPerTicketPerHour = 1
	rl.AlertPerTicketBurst = 1
	pusher := &fakePusher{outcome: PushOutcome{Status: 202}}
	server, _ := testServer(t, pusher, rl)
	ticket := registerAndGetTicket(t, server.Handler())

	// Exhaust the alert bucket.
	doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60})

	// A background push on the very same ticket is unaffected.
	rec := doJSON(t, server.Handler(), "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "background", TTLSeconds: 60})
	if rec.Code != http.StatusAccepted {
		t.Errorf("background push after exhausting the alert bucket: status = %d, want 202", rec.Code)
	}
}

func TestHealthz(t *testing.T) {
	server, _ := testServer(t, &fakePusher{}, generousRateLimits())
	rec := doJSON(t, server.Handler(), "GET", "/healthz", nil)
	if rec.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rec.Code)
	}
}

func TestMetricsEndpointExposesDeclaredNames(t *testing.T) {
	// A Prometheus CounterVec only emits a metric family once at least one label combination
	// has actually been incremented, so the test drives all three counters at least once
	// (success push, successful register, one tripped rate limit) rather than asserting on an
	// untouched collector.
	rl := generousRateLimits()
	rl.AlertPerTicketPerHour = 1
	rl.AlertPerTicketBurst = 1
	server, _ := testServer(t, &fakePusher{outcome: PushOutcome{Status: 202}}, rl)
	h := server.Handler()

	ticket := registerAndGetTicket(t, h)
	doJSON(t, h, "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60})
	doJSON(t, h, "POST", "/v1/push", pushRequest{Ticket: ticket, Type: "alert", Blob: "YWJjZA==", TTLSeconds: 60})

	rec := doJSON(t, h, "GET", "/metrics", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	body := rec.Body.String()
	for _, name := range []string{"mvrelay_push_total", "mvrelay_register_total", "mvrelay_ratelimited_total"} {
		if !strings.Contains(body, name) {
			t.Errorf("/metrics body is missing %q", name)
		}
	}
}
