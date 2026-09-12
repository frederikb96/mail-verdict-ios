# mail-verdict-push-relay

A Helm chart for the relay that forwards encrypted push notifications to Apple on behalf of any
self-hosted [MailVerdict](https://github.com/frederikb96/mail-verdict) server — see
`../../relay/README.md` for the API contract and what the service itself does and does not see.
This chart is generic: it makes no assumption about whose cluster it runs on or which ingress
controller fronts it. It does assume the installer is the app's publisher, since only the
publisher can hold an APNs credential for the app's bundle id — this is not a chart a MailVerdict
server operator installs for themselves.

## Before you install

You need:

- **An Apple Developer account** with a registered app and an **APNs Auth Key** (`.p8`) — App
  Store Connect → Certificates, Identifiers & Profiles → Keys. Note the key id and your team id.
- **A Kubernetes Secret holding that key**, created and managed however you prefer (SOPS,
  sealed-secrets, Vault, or a plain `kubectl create secret generic`). This chart never creates
  one itself.
- **A Kubernetes Secret holding the ticket-signing keys**, in the
  `<id>:<64 hex characters>,<id>:<64 hex characters>,...` format `../../relay/README.md`
  describes — generate the hex with something like `openssl rand -hex 32`.
- **A Kubernetes cluster** with an ingress controller and, if you want automatic TLS,
  cert-manager. Neither is bundled — this chart only creates the resources that point at them.
- **A hostname** this service will be reachable at, with DNS you can point at your cluster's
  ingress. Create the DNS record and let it resolve *before* installing if you're using
  cert-manager's HTTP-01 challenge — a certificate request against a hostname that doesn't
  resolve yet fails, and DNS caching can make that failure stick around longer than the actual
  propagation delay.

## Installing

Add the repository and install with your own values:

```
helm repo add mail-verdict-push-relay https://frederikb96.github.io/mail-verdict-ios/
helm repo update
helm install mail-verdict-push-relay mail-verdict-push-relay/mail-verdict-push-relay \
  --namespace mail-verdict-push-relay --create-namespace \
  -f my-values.yaml
```

Minimal `my-values.yaml`:

```yaml
apns:
  keyId: "YOUR_KEY_ID"
  teamId: "YOUR_TEAM_ID"
  bundleId: "com.yourname.yourapp"
  authKey:
    existingSecret: "apns-auth-key"

tickets:
  existingSecret: "ticket-signing-keys"

ingress:
  className: "nginx"          # or whatever your cluster's ingress controller is called
  host: "push.yourdomain.com"
  tls:
    secretName: "mail-verdict-push-relay-tls"
    certManager:
      enabled: true
      issuerName: "letsencrypt"   # your ClusterIssuer's name
```

The chart validates the values that have no reasonable default (`apns.keyId`, `apns.teamId`,
`apns.bundleId`, `apns.authKey.existingSecret`, `tickets.existingSecret`, `ingress.host`,
`ingress.tls.secretName` when TLS is on) and refuses to render without them — you'll get a clear
error naming exactly what's missing rather than a chart that installs and then fails quietly.

## Why both secrets are `existingSecret`-only

Unlike a chart whose secret is a webhook token or a shared password, these two values are an
Apple API credential and the keys that authorize every device ticket this relay will ever issue.
Neither has any business passing through Helm values or a rendered template on its way into the
cluster — you create the Secret however you already manage secrets, and this chart only ever
reads it.

## For whoever cuts the first release

A freshly-pushed GHCR package defaults to **private** even though the repository is public — one
manual step, once, before anyone can pull it without a token: GitHub → the repo → Packages →
`mail-verdict-push-relay` → Package settings → Change visibility → Public. Every later release to
the same package stays public; nothing in CI needs to repeat this.

## Everything the chart never assumes

No hardcoded hostname, bundle id, or ingress class — `ingress.host`, `apns.bundleId` and
`ingress.className` are all empty by default and either required or fall back to your cluster's
own default. The container image is public (`ghcr.io/frederikb96/mail-verdict-push-relay`, no
auth needed to pull), so the chart needs zero `imagePullSecrets`.

## Observability

`serviceMonitor.enabled: true` (plus whatever label your Prometheus Operator's own Prometheus CR
selects `ServiceMonitor`s by — `serviceMonitor.labels`) wires `/metrics` up for scraping. See
`../../relay/README.md`'s API section for what each metric means.

## Values reference

See `values.yaml` — every value is commented there; this README doesn't repeat them.
