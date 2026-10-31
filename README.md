# MailVerdict for iOS

[![Free checks](https://github.com/frederikb96/mail-verdict-ios/actions/workflows/free-checks.yml/badge.svg)](https://github.com/frederikb96/mail-verdict-ios/actions/workflows/free-checks.yml)
[![Release](https://img.shields.io/github/v/release/frederikb96/mail-verdict-ios)](https://github.com/frederikb96/mail-verdict-ios/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Native SwiftUI client for [MailVerdict](https://github.com/frederikb96/mail-verdict), a
self-hosted mail client with an AI spam layer. This app talks to a MailVerdict backend over its
REST and SSE API — it never speaks IMAP or SMTP itself, and the web UI there is the source of
truth for what this app ports.

## Connecting

On first launch, enter the backend's URL and, if the proxy in front of it needs one, a
credential: a bearer token, or a username and password for basic auth. A LAN, Tailscale or VPN
install with no proxy needs neither. Both are held on the device: the credential in the Keychain,
everything else in `UserDefaults`.

## Reading offline

Mail you have opened and the lists you have visited stay readable without the server: on a plane,
on a train, or while the server or the VPN in front of it is down.

- **What is kept:** the conversations opened most recently in the reader with their inline images
  and sender photos, the newest rows of the lists visited most recently, each folder's role
  (Inbox, Trash, …) so actions on saved mail are offered as online, and the Mailboxes overview.
  It is kept per server, in the app's Caches directory, bounded in count and size by
  `MVOfflineCache.Budget`, and readable only while the phone is unlocked. iOS may reclaim it under
  storage pressure; signing out deletes it.
- **When it is used:** only when a read fails because the server cannot be reached (no network, a
  host that does not answer, a timeout, or a 502/503/504 from the proxy). Any other answer from the
  server is shown as it is. Mailboxes falls back to its last overview the same way, however old.
- **What you see:** a capsule at the top of the list and the reader — "Offline", or "Server
  unreachable", with when the copy on screen was saved — and the list subtitle reads "Offline"
  without a network, or "Connecting…" while the server does not answer. A message that was never
  opened says it is not saved on this device.
- **Actions:** read, star, archive, delete, move and junk are queued on the device and sent when
  the connection is back, as they always are; the list says how many are waiting. Everything else
  that needs the server (sending, search, verdict feedback, loading images, attachments, Show in
  Folder, Select All, Mark All as Read, Empty Folder, pull to refresh) fails with a message saying
  why, such as "No internet connection."
- **Short hiccups:** a read that fails because the connection dropped or the proxy answered 502/504
  is asked again shortly before anything shows an error, and a read that hears nothing gives up
  well before the system's one-minute timeout (both in `MVReadRetryPolicy`). A network loss
  shorter than `MVNetworkStatus.defaultOfflineGrace` does not show as offline, and the live
  connection reconnects as soon as the network returns. Writes are never repeated by the
  transport; mail actions are retried by the app's action queue, which knows whether an attempt
  may already have landed.
- **Coming back online:** as soon as the network or the live connection returns, saved lists and
  messages are read again, and those that had nothing saved load. A copy shown while the live
  connection stayed up (a timeout or a 503) is read again on a short, bounded schedule
  (`MVSavedCopyRetry`). A saved list is replaced by the server's answer, never merged with it; a
  saved message the server no longer has leaves the screen; a message is marked read only once
  the server has answered for it.

## Orders and tickets

Orders & Tickets (from Mailboxes) is the wallet for what the server's order register collects from
mail and files.

- **Choosing a view:** a segmented control picks All, Orders or Tickets; the Open and Favorites
  chips narrow any of them and combine with it (Open + Tickets is what is still ahead). The choice
  survives a relaunch.
- **Tickets are a timeline:** by the day they are for, what is ahead above a "Today" marker and
  what has passed below. It opens with the marker in the middle of the screen and keeps it there
  until you first touch the list. Coming back from a ticket keeps your place; Today jumps back to
  the marker.
- **Key facts:** an order shows its numbers, dates, places, seats and amounts. A tracking number
  opens the carrier's page, a link opens in the browser, anything else copies on tap.
- **Codes:** the QR, Aztec and barcodes of a ticket show as thumbnails. Tapping one shows it
  fullscreen on white at full brightness with the display kept awake; leaving it, or the app
  leaving the foreground, puts the brightness back.
- **Files:** Add File and Add Photo on an order (and the plus on the list, which lets the server
  pick the order) send a document to be read into the order. HEIC photos are converted to JPEG
  first, since the server stores HEIC but cannot read it. Documents of an order, mail attachments and added
  files alike, open in the system preview; an added file can be deleted.
- **Without reception:** the detail of every ticket you open, its codes, and the ticket timeline
  are saved on the device; the tickets for today and later are saved ahead of time whenever the
  list loads. They are used under the same rule as saved mail (only when the server cannot be
  reached) and the capsule says so.

## Sharing into MailVerdict

MailVerdict appears in the iOS share sheet for files, images, text and links (it may need switching
on once: scroll the sheet's app row to More and enable it). The sheet offers two things:

- **Add to Orders:** each file is sent to the orders pipeline, which reads it and places it on an
  order or ticket. Images are fitted to 2,000 px on the long side and HEIC becomes JPEG, since
  Orders reads only PNG and JPEG among images.
- **New mail in an account:** saves a draft in that account with every shared file attached and
  no recipient. The composer does not open; the draft is in Drafts afterwards. The account used
  last is listed first. A draft from the sheet takes up to 20 files and 32 MB together, because
  the extension builds the upload in memory; bigger selections are attached in the app.

The extension reads the backend address and credential from the Keychain group the app already
holds, so it needs no setup of its own; the app publishes the address on launch and withdraws it on
sign-out. If the app is signed out or the server refuses the credential, the sheet says to open
MailVerdict. A share is sent from inside the sheet, which has to stay open until it finishes.

## Shortcuts

The Shortcuts app lists MailVerdict's actions: New Message, Open Tickets, Tickets, Open Orders,
Orders & Tickets, Open Unified View (asks which one) and Search Mail. Each brings the app to the
front on that screen, so Add to Home Screen on a shortcut built from one makes a one-tap icon. The
same actions answer Siri and Spotlight.

## How it is arranged

Almost everything lives in `MailVerdictKit`, a local Swift package. **The package builds and
tests on Linux; the app target compiles only on macOS.** That split is the whole architecture:
package code is proven in seconds for free, app-target code is proven only when a macOS runner
runs — so views stay thin, and anything a unit test could catch lives in the package.

| Path | What |
|---|---|
| `MailVerdictKit/` | the logic and its tests |
| `MailVerdict/` | app target: views, and the few things needing an Apple framework. A buildable folder, so new files need no project edit |
| `MailVerdictNotify/`, `MailVerdictShare/` | the notification service extension and the share extension, each its own target and bundle id |
| `MailVerdict.xcodeproj` | written by hand, small, not regenerated by any tool |
| `Config/` | xcconfig; `MARKETING_VERSION` comes from the git tag via CI |
| `Tooling/` | checks that catch macOS-only compile errors without a Mac; `sim/` is the simulator lane the `Mac` workflow runs, usable on any Mac |
| `fastlane/` | build, sign, upload — the same lanes locally and in CI |

## Building and checks

The package needs only a Swift toolchain, 6.2.4 or later, on any platform (6.2.1 fails to link the
tests on Linux):

```
swift build --package-path MailVerdictKit --build-tests && \
  swift test --package-path MailVerdictKit --skip-build
swift format lint --recursive --strict MailVerdictKit MailVerdict MailVerdictNotify MailVerdictShare
```

Scans for what only a Mac would otherwise find: `./Tooling/parse-swift.sh` checks the app and
extension sources for syntax errors without an iOS SDK, `./Tooling/swift6-lint.py` flags Swift 6
constructs that compile on Linux and fail on a Mac, and `plutil -lint
MailVerdict.xcodeproj/project.pbxproj` validates the hand-written project file after an edit.

The app target needs Xcode. CI builds it on a macOS runner.

## CI

Checks run on pull requests only; `main` runs nothing, and the `Validation` job of `Free checks` is
the required gate.

| Workflow | Answers | Runner | Runs on |
|---|---|---|---|
| `Free checks` | compiles, tests pass, formatted; nightly, the vendored API contract still matches the backend | Linux | pull requests, manual dispatch, nightly |
| `Mac` | the app target compiles and the built bundle declares what it needs; with the simulator lane (manual dispatch only) it also boots the app, screenshots every registered screen (fixture mode, no backend needed) and queries the debug bridge | macOS | pull requests that change the app, package, extension or project (through `Free checks`), manual dispatch, and before every `Release` upload |
| `Relay checks` | the push relay's Go tests, vet, formatting and Helm chart render | Linux | pull requests that change `relay/` or the chart (through `Free checks`), manual dispatch |
| `Release` | signs and ships the app to TestFlight | macOS | a `v*.*.*` tag, manual dispatch |
| `Relay release` | publishes the relay image and Helm chart to GHCR | Linux | a `relay-v*.*.*` tag |

A dispatch can ask one question: `gh workflow run mac.yml -f only=list,reader-default` runs just those
screens, and `-f script=<path>` sources a probe from the branch after them.

`Mac` publishes a screenshot per registered screen plus the device log as artifacts, because every
automated assertion in that job can pass while the screen renders nothing.

## Releasing

Push a `v*.*.*` tag, or dispatch the workflow. The tag is the single source of truth for the
version; the build number is the CI run number. TestFlight builds expire after 90 days;
dispatching with `refresh_tag` rebuilds an existing release under a new build number to keep an
installed copy launching.

The push relay (`relay/`, `charts/mail-verdict-push-relay/`) is versioned and released
independently: a `relay-v*.*.*` tag publishes its image and chart. The tag versions only the image,
so the chart's `version` and `appVersion` are bumped to match in a pull request merged before
tagging.
