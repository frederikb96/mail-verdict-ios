package main

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// idleLimiterTTL is how long a per-key limiter (one per ticket_id, one per source IP) is kept
// around with no traffic before it is swept. Generous relative to every bucket's own window
// (at most a day) so a legitimate caller's burst allowance survives a quiet spell, while a
// one-off caller's entry does not accumulate forever in memory — this relay has no database and
// no eviction policy beyond this.
const idleLimiterTTL = 48 * time.Hour

// keyedLimiter is one rate-limit scope (e.g. "alert pushes per ticket"), holding one token
// bucket per key. It exists because golang.org/x/time/rate.Limiter is scoped to a single
// caller, and this relay needs independent buckets per ticket and per source IP.
type keyedLimiter struct {
	mu       sync.Mutex
	limiters map[string]*limiterEntry
	r        rate.Limit
	burst    int
}

type limiterEntry struct {
	limiter  *rate.Limiter
	lastUsed time.Time
}

// newKeyedLimiter builds a scope allowing perWindow events per window, refilling continuously,
// with up to burst allowed at once.
func newKeyedLimiter(perWindow int, window time.Duration, burst int) *keyedLimiter {
	return &keyedLimiter{
		limiters: make(map[string]*limiterEntry),
		r:        rate.Limit(float64(perWindow) / window.Seconds()),
		burst:    burst,
	}
}

// Allow reports whether key may act now, creating its bucket on first use.
func (k *keyedLimiter) Allow(key string, now time.Time) bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	e, ok := k.limiters[key]
	if !ok {
		e = &limiterEntry{limiter: rate.NewLimiter(k.r, k.burst)}
		k.limiters[key] = e
	}
	e.lastUsed = now
	return e.limiter.AllowN(now, 1)
}

// sweep drops any key untouched for longer than idleLimiterTTL.
func (k *keyedLimiter) sweep(now time.Time) {
	k.mu.Lock()
	defer k.mu.Unlock()
	for key, e := range k.limiters {
		if now.Sub(e.lastUsed) > idleLimiterTTL {
			delete(k.limiters, key)
		}
	}
}

// RateLimiters bundles every scope this relay enforces, one keyedLimiter per row of the table
// in README.md's "Rate limits" section.
type RateLimiters struct {
	AlertPerTicket      *keyedLimiter
	AlertPerTicketDaily *keyedLimiter
	BackgroundPerTicket *keyedLimiter
	IPPushes            *keyedLimiter
	IPRegistrations     *keyedLimiter

	// retryAfter is the value reported in a 429's retry_after_seconds per scope: the time for
	// one token to regenerate, rounded up. An approximation — the bucket may refill sooner if
	// it was only partially drained — but it is always a safe (never too short) amount to wait.
	retryAfter map[*keyedLimiter]time.Duration
}

func NewRateLimiters(cfg RateLimitConfig) *RateLimiters {
	alertPerTicket := newKeyedLimiter(cfg.AlertPerTicketPerHour, time.Hour, cfg.AlertPerTicketBurst)
	alertPerTicketDaily := newKeyedLimiter(cfg.AlertPerTicketPerDay, 24*time.Hour, cfg.AlertPerTicketPerDay)
	backgroundPerTicket := newKeyedLimiter(cfg.BackgroundPerTicketPerHour, time.Hour, cfg.BackgroundPerTicketBurst)
	ipPushes := newKeyedLimiter(cfg.IPPushesPerHour, time.Hour, cfg.IPPushesBurst)
	ipRegistrations := newKeyedLimiter(cfg.IPRegistrationsPerHour, time.Hour, cfg.IPRegistrationsBurst)

	retryAfter := map[*keyedLimiter]time.Duration{
		alertPerTicket:      durationPerToken(cfg.AlertPerTicketPerHour, time.Hour),
		alertPerTicketDaily: durationPerToken(cfg.AlertPerTicketPerDay, 24*time.Hour),
		backgroundPerTicket: durationPerToken(cfg.BackgroundPerTicketPerHour, time.Hour),
		ipPushes:            durationPerToken(cfg.IPPushesPerHour, time.Hour),
		ipRegistrations:     durationPerToken(cfg.IPRegistrationsPerHour, time.Hour),
	}

	return &RateLimiters{
		AlertPerTicket:      alertPerTicket,
		AlertPerTicketDaily: alertPerTicketDaily,
		BackgroundPerTicket: backgroundPerTicket,
		IPPushes:            ipPushes,
		IPRegistrations:     ipRegistrations,
		retryAfter:          retryAfter,
	}
}

// RetryAfter reports how long a caller who just tripped limiter should wait.
func (rl *RateLimiters) RetryAfter(limiter *keyedLimiter) time.Duration {
	return rl.retryAfter[limiter]
}

// StartSweeper runs a periodic cleanup of every scope's idle entries until ctx is cancelled.
func (rl *RateLimiters) StartSweeper(done <-chan struct{}, interval time.Duration) {
	all := []*keyedLimiter{rl.AlertPerTicket, rl.AlertPerTicketDaily, rl.BackgroundPerTicket, rl.IPPushes, rl.IPRegistrations}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case now := <-ticker.C:
				for _, l := range all {
					l.sweep(now)
				}
			}
		}
	}()
}

func durationPerToken(perWindow int, window time.Duration) time.Duration {
	if perWindow <= 0 {
		return window
	}
	d := window / time.Duration(perWindow)
	if d < time.Second {
		return time.Second
	}
	return d
}
