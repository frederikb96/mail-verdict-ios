# Two stages: build a static binary with the Go toolchain, then ship nothing else. There is no
# runtime dependency (no interpreter, no shared libs to pin) — this is a small, always-on service
# that any self-hoster's cluster pulls sight-unseen.
FROM docker.io/library/golang:1.27-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
# CGO_ENABLED=0 is what makes the binary static — cross-building this on an arm64 CI runner for
# an amd64 node (or the reverse) must never silently link against the build host's libc.
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mail-verdict-push-relay .

# distroless/static, not scratch: this binary makes outbound TLS calls to Apple's API and needs
# the CA bundle static-debian12 already carries — scratch would need one copied in by hand, one
# more thing to keep in sync with the build image's own certs.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/mail-verdict-push-relay /mail-verdict-push-relay

# distroless/static's nonroot image already runs as uid 65532 — the chart's own securityContext
# pins the same value explicitly rather than trusting the image default silently — so no USER
# directive is needed here.
ENTRYPOINT ["/mail-verdict-push-relay"]
