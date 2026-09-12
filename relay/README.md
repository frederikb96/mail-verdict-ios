# mail-verdict-push-relay

A small stateless relay that forwards encrypted push notifications to Apple on behalf of any
self-hosted MailVerdict server. Only the publisher of the MailVerdict iOS app can sign pushes for
its bundle id, so every self-hosted server — including the one running this relay's own
deployment — sends its pushes through this one service rather than holding an Apple credential
itself.

This document is the relay's HTTP API contract. A MailVerdict server and the iOS app both
implement against it; nothing here describes a private deployment detail.

## Shape

- **No authentication header.** A sealed, expiring "push ticket" issued by `/v1/register` is the
  only credential a caller presents, and it authorizes exactly one APNs device token. There is no
  account, API key or registration step a server operator performs with the relay operator —
  the phone registers directly.
- **Nothing is stored.** No database, no volume. A ticket is self-contained: everything needed to
  validate and open it is encoded in the ticket itself, sealed with a key only the relay holds.
  Restarting the relay, or rotating its signing key, invalidates nothing already-issued tickets
  can't still prove — a dropped key simply makes its tickets fail to open, which the caller sees
  as an expired ticket.
- **The relay never reads the notification content.** A push's `blob` is an opaque,
  end-to-end-encrypted value the relay forwards to Apple unmodified. Only the phone's own
  notification extension can decrypt it; the relay and the MailVerdict server it came from both
  see ciphertext only, for `alert`-type pushes. Everything the relay needs to route the push
  (type, a collapse id, a time-to-live) travels outside the blob, in plain request fields.
- **One sender topic for every installation.** Every MailVerdict server that uses a given relay
  deployment is pushing to the same app bundle id, because only the app's one publisher can hold
  the Apple credential that signs for that bundle id. A relay deployment is therefore always
  paired with exactly one app build.

## Registration handshake

- A phone registers its APNs device token with the relay directly: `POST /v1/register`.
- The relay returns a ticket bound to that token, with an expiry.
- The phone hands the ticket (and a content encryption key it generated itself, which never
  reaches the relay) to its own MailVerdict server.
- The server later calls `POST /v1/push` with that ticket whenever it has something to deliver.
  The relay opens the ticket to recover the device token, and forwards the push to Apple — it
  never sees which server sent it beyond the caller's IP address, and never sees why.
- A ticket is revoked by a new relay signing key rotation, or simply expires on its own schedule.
  There is no unregister endpoint: the only way to stop a server from pushing to a device is for
  the phone to stop refreshing its ticket with that server.

## API

All endpoints are JSON over HTTPS. Responses whose status code is 400, 413 or 502 carry a short
plain-text message rather than a JSON body; every other response shown below is JSON.

### `POST /v1/register`

Request:

```json
{"apns_token": "<hex device token, 16-200 characters, even length>"}
```

Response `200`:

```json
{"ticket": "<opaque string>", "ticket_id": "<16 hex characters>", "expires_at": "<RFC3339 UTC>"}
```

- `ticket` is opaque to every caller — store and forward it verbatim, never parse it.
- `ticket_id` is a stable, non-secret fingerprint of the ticket. It is the only per-device value
  that ever appears in the relay's logs or metrics, and is safe to log on the calling side too.
- `expires_at` is when the ticket stops working. Re-register well before then — the app should
  treat a ticket nearing expiry (or a `401 TicketExpired` from a push) as "register again."

Errors:

- `400` — `apns_token` missing, the wrong length, or not a hex string.
- `429` — rate limited; retry later.

### `POST /v1/push`

Request:

```json
{
  "ticket": "<from /v1/register>",
  "type": "alert",
  "blob": "<base64, required when type is \"alert\", at most 3072 characters>",
  "collapse_id": "<at most 64 bytes, optional>",
  "ttl_seconds": 300
}
```

`type` is `"alert"` (a user-visible notification; carries `blob`) or `"background"` (a silent
wake-up; carries no `blob`). `ttl_seconds` is `0`-`86400`; `0` asks Apple for best-effort,
immediate-or-never delivery rather than a held, retried one.

Response `202`:

```json
{"apns_id": "<Apple's own identifier for the accepted push>"}
```

Errors:

- `400` — malformed request (missing/invalid field, wrong type, `blob` present for a
  `background` push or absent for an `alert` one).
- `401` — `{"reason": "InvalidTicket"}` (cannot be opened — wrong, corrupted, or signed by a
  since-rotated key) or `{"reason": "TicketExpired"}` (opened fine, but past its `expires_at`).
  Either means: stop retrying this push, and tell the phone to register again.
- `410` — `{"reason": "Unregistered" | "BadDeviceToken" | "DeviceTokenNotForTopic"}`. Apple has
  told the relay this device token will never accept another push. Delete whatever local
  subscription record this ticket belongs to — retrying is pointless.
- `413` — the request body, or `blob`, exceeded the size limits above.
- `429` — `{"retry_after_seconds": <int>}`. Either this ticket or the caller's own IP address hit
  a rate limit; back off for at least the given duration. Transient — retry later, don't drop
  anything.
- `502` — Apple's API itself failed or timed out. Transient — retry with backoff, same as any
  other upstream failure.

### `GET /healthz`

`200` with a plain-text body once the process is up. No dependency to check — there is nothing
this service depends on besides Apple's own API, which it only calls per-request.

### `GET /metrics`

Prometheus text format:

- `mvrelay_push_total{type="alert|background", result="success|gone|ratelimited|failure"}`
- `mvrelay_register_total{result="success|invalid|ratelimited"}`
- `mvrelay_ratelimited_total{scope="ticket_alert|ticket_alert_daily|ticket_background|ip_push|ip_register"}`

## Rate limits

Enforced in memory, per process, reset on a restart — accepted, since the cost of a restart
costing a few minutes of limits is far lower than the cost of a shared store this service would
otherwise need to hold no other state at all. A caller that hits a limit gets a `429`, not a
dropped request.

| Scope | Limit |
|---|---|
| Alert pushes, per ticket | 60/hour (burst 30), 500/day |
| Background pushes, per ticket | 12/hour |
| Pushes, per source IP | 1200/hour |
| Registrations, per source IP | 30/hour |
| Request body | 8 KB |
| `blob` field | 3072 characters |

A reverse proxy in front of a given deployment may also apply its own, coarser rate limiting —
that is a second, independent layer, not a replacement for the limits above.

## What the relay sees, and what it never sees

- **Sees, transiently, per request:** the caller's source IP, the device token (held in memory
  only for the duration of the one request that needs it), the `ticket_id`, the push type, and
  the `blob`'s size and timing.
- **Never sees:** a mail subject, sender, account identifier, message content, badge count, or
  anything that would identify which MailVerdict server a device belongs to, beyond IP address
  correlation across requests.
- **Logs:** `ticket_id` and the outcome of a request. Never a device token, a ticket, or a
  `blob`.

A ticket authorizes pushing to exactly one device, within the rate limits above, and expires on
its own. Holding a valid ticket never reveals the device token it was issued for, and opening a
blob it delivers needs a content key the relay never has — so a compromised ticket lets its
holder push (bounded) notifications to one device, and nothing more.

## Building and testing

```
go vet ./...
go test ./...
go build ./...
podman build -t mail-verdict-push-relay:local .
```

The image is `CGO_ENABLED=0`, built from the Go toolchain and shipped on
`distroless/static-debian12:nonroot` — no shell, no package manager, nothing beyond the static
binary and the CA bundle it needs to reach Apple's API over TLS.

## Configuration

Every value is an environment variable — see `charts/mail-verdict-push-relay/values.yaml` in this
repository for the Helm chart that wires them up, with every default commented there. Nothing
here has a default that silently masks a missing required value: the process refuses to start
rather than guess.
