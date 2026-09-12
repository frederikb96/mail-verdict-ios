package main

import (
	"context"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

// sendTimeout bounds one push's whole round trip to Apple, so a hung HTTP/2 stream never wedges
// an HTTP handler (and the request that is waiting on it) forever.
const sendTimeout = 30 * time.Second

// PushRequest is everything one call to Push needs — the caller, not this file, is responsible
// for having already opened the ticket and validated every field against the API contract.
type PushRequest struct {
	DeviceToken []byte
	// Kind is "alert" or "background", matching the API's type field exactly.
	Kind       string
	Blob       string // base64, alert only — opaque to this file too.
	CollapseID string
	TTL        time.Duration
}

// PushOutcome is what Push decided the caller's HTTP response should be: the status code this
// relay's own API contract promises for /v1/push, plus whatever fields that status carries.
type PushOutcome struct {
	Status     int
	Reason     string
	ApnsID     string
	RetryAfter time.Duration
}

// Pusher sends one push and reports the outcome — an interface so handlers are tested against a
// fake, never a real APNs connection.
type Pusher interface {
	Push(ctx context.Context, req PushRequest) PushOutcome
}

// APNSPusher is the real Pusher: a thin wrapper around sideshow/apns2's token-based client. One
// client for the process lifetime — APNs expects a long-lived HTTP/2 connection reused across
// pushes, not one connection per send.
type APNSPusher struct {
	client        *apns2.Client
	topic         string
	fallbackTitle string
	fallbackBody  string
}

// NewAPNSPusher loads the .p8 key from keyPath and builds a production APNs client. There is no
// sandbox/production switch: every build this relay ever serves — TestFlight or App Store — only
// ever talks to APNs production.
func NewAPNSPusher(keyPath, keyID, teamID, topic, fallbackTitle, fallbackBody string) (*APNSPusher, error) {
	authKey, err := token.AuthKeyFromFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("loading APNs auth key from %q: %w", keyPath, err)
	}
	tok := &token.Token{AuthKey: authKey, KeyID: keyID, TeamID: teamID}
	client := apns2.NewTokenClient(tok).Production()
	return &APNSPusher{
		client:        client,
		topic:         topic,
		fallbackTitle: fallbackTitle,
		fallbackBody:  fallbackBody,
	}, nil
}

func (p *APNSPusher) Push(ctx context.Context, req PushRequest) PushOutcome {
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()

	n := &apns2.Notification{
		DeviceToken: hex.EncodeToString(req.DeviceToken),
		Topic:       p.topic,
		CollapseID:  req.CollapseID,
	}
	if req.TTL > 0 {
		// A zero Expiration omits the apns-expiration header entirely, which apns2 and Apple
		// both treat as "do not store, attempt once" — exactly ttl_seconds: 0's documented
		// meaning, so there is nothing to set in that case.
		n.Expiration = time.Now().Add(req.TTL)
	}

	switch req.Kind {
	case "alert":
		n.Payload = payload.NewPayload().
			AlertTitle(p.fallbackTitle).
			AlertBody(p.fallbackBody).
			MutableContent().
			Sound("default").
			Custom("mv", map[string]any{"v": 1, "b": req.Blob})
		n.PushType = apns2.PushTypeAlert
		n.Priority = apns2.PriorityHigh
	case "background":
		n.Payload = payload.NewPayload().ContentAvailable()
		n.PushType = apns2.PushTypeBackground
		n.Priority = apns2.PriorityLow
	}

	res, err := p.client.PushWithContext(ctx, n)
	if err != nil {
		return PushOutcome{Status: 502, Reason: err.Error()}
	}
	return classify(res.StatusCode, res.ApnsID, res.Reason)
}

// goneReason reports whether Apple's reason string means this device token will never accept
// another push, regardless of which HTTP status carried it — APNs documents all three as
// permanent, not transient, failures.
func goneReason(reason string) bool {
	switch reason {
	case "Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic":
		return true
	default:
		return false
	}
}

// classify turns one APNs response into this relay's own outcome — pure and separate from Push
// so it is tested without a network call.
func classify(statusCode int, apnsID, reason string) PushOutcome {
	if statusCode == 200 {
		return PushOutcome{Status: 202, ApnsID: apnsID}
	}
	if statusCode == 410 || goneReason(reason) {
		return PushOutcome{Status: 410, Reason: reason}
	}
	if statusCode == 429 {
		return PushOutcome{Status: 429, Reason: reason, RetryAfter: 60 * time.Second}
	}
	return PushOutcome{Status: 502, Reason: reason}
}
