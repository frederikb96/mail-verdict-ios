package main

import (
	"testing"
	"time"
)

func TestKeyedLimiterTripsAtBurst(t *testing.T) {
	// 60/hour, burst 5: the first 5 calls at the same instant succeed, the 6th does not.
	kl := newKeyedLimiter(60, time.Hour, 5)
	now := time.Now()

	for i := 0; i < 5; i++ {
		if !kl.Allow("ticket-a", now) {
			t.Fatalf("call %d: Allow = false, want true (within burst)", i+1)
		}
	}
	if kl.Allow("ticket-a", now) {
		t.Error("call 6: Allow = true, want false (burst exhausted)")
	}
}

func TestKeyedLimiterBucketsAreIndependentPerKey(t *testing.T) {
	kl := newKeyedLimiter(60, time.Hour, 1)
	now := time.Now()

	if !kl.Allow("ticket-a", now) {
		t.Fatal("ticket-a's first call should succeed")
	}
	if kl.Allow("ticket-a", now) {
		t.Error("ticket-a's second call should be rate limited")
	}
	if !kl.Allow("ticket-b", now) {
		t.Error("ticket-b should have its own, untouched bucket")
	}
}

func TestKeyedLimiterRefillsOverTime(t *testing.T) {
	// 3600/hour == 1/second, burst 1: exhausted immediately, but refilled a second later.
	kl := newKeyedLimiter(3600, time.Hour, 1)
	now := time.Now()

	if !kl.Allow("ticket-a", now) {
		t.Fatal("first call should succeed")
	}
	if kl.Allow("ticket-a", now) {
		t.Fatal("immediate second call should be rate limited")
	}
	if !kl.Allow("ticket-a", now.Add(2*time.Second)) {
		t.Error("call two seconds later should have refilled")
	}
}

func TestKeyedLimiterSweepDropsOnlyIdleKeys(t *testing.T) {
	kl := newKeyedLimiter(60, time.Hour, 5)
	now := time.Now()

	kl.Allow("idle", now)
	kl.Allow("active", now)

	later := now.Add(idleLimiterTTL + time.Minute)
	kl.Allow("active", later) // touches "active" again, so it is not idle at sweep time

	kl.sweep(later)

	kl.mu.Lock()
	_, idleStillPresent := kl.limiters["idle"]
	_, activeStillPresent := kl.limiters["active"]
	kl.mu.Unlock()

	if idleStillPresent {
		t.Error("sweep left an entry untouched for longer than idleLimiterTTL")
	}
	if !activeStillPresent {
		t.Error("sweep dropped an entry that was touched recently")
	}
}

func TestRateLimitersEnforceConfiguredScopesIndependently(t *testing.T) {
	rl := NewRateLimiters(RateLimitConfig{
		AlertPerTicketPerHour:      2,
		AlertPerTicketBurst:        2,
		AlertPerTicketPerDay:       100,
		BackgroundPerTicketPerHour: 1,
		BackgroundPerTicketBurst:   1,
		IPPushesPerHour:            100,
		IPPushesBurst:              100,
		IPRegistrationsPerHour:     100,
		IPRegistrationsBurst:       100,
	})
	now := time.Now()

	if !rl.AlertPerTicket.Allow("t1", now) || !rl.AlertPerTicket.Allow("t1", now) {
		t.Fatal("expected two alert pushes to fit within burst 2")
	}
	if rl.AlertPerTicket.Allow("t1", now) {
		t.Error("a third alert push in the same instant should trip the per-ticket bucket")
	}

	// A different ticket's background bucket is untouched by t1's alert bucket tripping.
	if !rl.BackgroundPerTicket.Allow("t1", now) {
		t.Error("background bucket should be independent of the alert bucket for the same ticket")
	}
}

func TestRetryAfterIsPositiveForEveryScope(t *testing.T) {
	rl := NewRateLimiters(RateLimitConfig{
		AlertPerTicketPerHour:      60,
		AlertPerTicketBurst:        30,
		AlertPerTicketPerDay:       500,
		BackgroundPerTicketPerHour: 12,
		BackgroundPerTicketBurst:   12,
		IPPushesPerHour:            1200,
		IPPushesBurst:              1200,
		IPRegistrationsPerHour:     30,
		IPRegistrationsBurst:       30,
	})

	for _, l := range []*keyedLimiter{rl.AlertPerTicket, rl.AlertPerTicketDaily, rl.BackgroundPerTicket, rl.IPPushes, rl.IPRegistrations} {
		if rl.RetryAfter(l) <= 0 {
			t.Errorf("RetryAfter for a configured scope = %v, want > 0", rl.RetryAfter(l))
		}
	}
}
