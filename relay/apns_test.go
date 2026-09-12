package main

import "testing"

func TestClassify(t *testing.T) {
	cases := []struct {
		name       string
		statusCode int
		apnsID     string
		reason     string
		wantStatus int
	}{
		{"accepted", 200, "abc-123", "", 202},
		{"explicit 410", 410, "", "Unregistered", 410},
		{"400 with a permanently-bad reason is still treated as gone", 400, "", "BadDeviceToken", 410},
		{"400 with DeviceTokenNotForTopic is gone", 400, "", "DeviceTokenNotForTopic", 410},
		{"429 from Apple becomes our 429", 429, "", "TooManyRequests", 429},
		{"an ordinary 400 with an unrelated reason is a gateway failure", 400, "", "BadCollapseId", 502},
		{"a 500 from Apple is a gateway failure", 500, "", "InternalServerError", 502},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := classify(c.statusCode, c.apnsID, c.reason)
			if got.Status != c.wantStatus {
				t.Errorf("classify(%d, _, %q).Status = %d, want %d", c.statusCode, c.reason, got.Status, c.wantStatus)
			}
		})
	}
}

func TestClassifySuccessCarriesApnsID(t *testing.T) {
	got := classify(200, "the-apns-id", "")
	if got.ApnsID != "the-apns-id" {
		t.Errorf("ApnsID = %q, want %q", got.ApnsID, "the-apns-id")
	}
}

func TestClassifyGoneCarriesReason(t *testing.T) {
	got := classify(410, "", "Unregistered")
	if got.Reason != "Unregistered" {
		t.Errorf("Reason = %q, want %q", got.Reason, "Unregistered")
	}
}

func TestClassifyRateLimitedCarriesRetryAfter(t *testing.T) {
	got := classify(429, "", "TooManyRequests")
	if got.RetryAfter <= 0 {
		t.Errorf("RetryAfter = %v, want > 0", got.RetryAfter)
	}
}
