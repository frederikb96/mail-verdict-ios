# Porting backlog

Deferred parity work against [mail-verdict](https://github.com/frederikb96/mail-verdict)'s web
UI — entries that need an Xcode/simulator or a real device to verify, never a field, an enum case
or a `CodingKey`. Those are cheap and get ported immediately, not listed here. Append-only: add an
entry, never edit or reorder another agent's.

## Entry format

```
### <what> — web anchor: <path or symbol>
Needs a device because: <one line>
```

Remove an entry once it is ported. A backlog that keeps finished work reads as a list of things
still owed, and the next agent either redoes them or stops trusting the file.

## Backlog

### A mid-row swipe right archives without popping the screen — web anchor: n/a (native gesture)
Needs a device because: the edge-swipe-to-go-back gesture and a mid-row swipe-to-archive gesture
share the same screen edge; only a real touch can tell whether the reader's and the list's own
content-pop disable/restore agree when pushing and popping.

### Swipe actions: full right archives, full left deletes (no snap-back), short left shows Options + Delete — web anchor: n/a (native gesture)
Needs a device because: `UISwipeActionsConfiguration`'s full-swipe threshold and the row's removal
animation are driven by real touch velocity, not reproducible from a script. In Trash, a full-swipe
Delete Forever must ask and leave the row in place until confirmed.

### A two-finger pan enters select mode and ticks rows — web anchor: n/a (native gesture)
Needs a device because: `shouldBeginMultipleSelectionInteractionAt` only fires for a genuine
two-finger touch. Under Select All, every visible row must show ticked, and unticking one must
exclude it.

### The measured row height holds at the smallest and largest Dynamic Type sizes — web anchor: n/a (native accessibility setting)
Needs a device because: Dynamic Type categories are a device/simulator accessibility setting: no
row may clip, and changing the category while the reader is open must keep its row in place.

### Open, Back returns to the same row and offset — web anchor: n/a (native scroll restoration)
Needs a device because: `/list/state`'s first-visible-row id and `offsetInRow` must match before
and after Open/Back, and again after an archive performed from the reader while it's open —
UIKit's own scroll-position bookkeeping isn't exercised by the fixture sweep's scripted navigation.

### Rows scroll correctly under the glass nav bar and bottom bar — web anchor: n/a (native chrome)
Needs a device because: `contentInset`/`adjustedContentInset` under the translucent bars, and
whether the first row is hidden under the nav bar at the top, only render on real glass materials.

### The search field's placement in select mode, and a five-action bottom bar — web anchor: n/a (native toolbar)
Needs a device because: `DefaultToolbarItem(kind: .search, placement: .bottomBar)` removing itself
when select mode starts is a layout question a screenshot sweep with no scripted select-mode entry
doesn't exercise end to end.

### navigationSubtitle reads "Updated …" / "Filtered by: Unread" — web anchor: n/a (native subtitle)
Needs a device because: `navigationSubtitle` rendering under the inline title is an iOS 26 API
with no Linux or prior-art compile check; only a real render confirms the two lines read right
together.

### Relaunch lands on the saved row at the same point — web anchor: n/a (native persistence)
Needs a device because: `MVListPositionStore`'s anchor restoration runs through a real app
relaunch (process death, not just a screen navigation), which the fixture sweep's scripted
per-screen launches don't reproduce.

### The literal swipe-revealed-buttons screenshot — web anchor: n/a (native gesture)
Needs a device because: nothing in `mac.yml` drives a real swipe gesture (`idb ui swipe` would be
the mechanism); `list-swipe-options` currently captures the Options sheet a swipe opens, not the
mid-swipe reveal itself.

### reader.js works with page JavaScript off — web anchor: ui/src/components/email-renderer (fit-to-width, find, canvas toggle)
Needs a device because: the injected `WKUserScript`'s fit-to-width `zoom`, the Custom Highlight
API find, and the canvas (dark/light) toggle all run inside a real `WKWebView` content process.

### The pager stands still while a message is zoomed — web anchor: n/a (native gesture)
Needs a device because: pinch-to-zoom and the scroll-view delegate's zoom forwarding need a real
pinch gesture; the pinch-end backstop that re-enables paging is itself gated on a genuine gesture
ending.

### A horizontal swipe pages at zoom 1 and pans after a pinch — web anchor: n/a (native gesture, Photos-style paging)
Needs a device because: distinguishing "paging swipe" from "panning swipe" depends on
`gestureRecognizerShouldBegin`'s real-time zoom-scale check during an actual touch sequence.

### Find in Message highlights paint inside the declarative shadow root — web anchor: n/a (native WKFindInteraction)
Needs a device because: the Custom Highlight API's paint-only find has no `<mark>` fallback built,
and a `UIFindInteraction` panel only opens with a real find gesture/keyboard shortcut.

### The screen-edge swipe goes Back; a mid-screen right swipe pages to the newer message — web anchor: n/a (native gesture)
Needs a device because: both gestures share similar start geometry; only real touch disambiguates
edge-pop from mid-screen paging.

### The fixture newsletter's contentWidth equals boundsWidth at zoom 1 — web anchor: n/a (native WKWebView layout)
Needs a device because: `/reader/state`'s `contentWidth`/`boundsWidth` comparison needs the page
actually laid out and fit-to-width applied inside a real web view.

### Zoomed-edge handoff: overshoot pages, a small sideways move never pages, a mid-content drag only pans — web anchor: n/a (native gesture, `MVZoomEdgeHandoff` tunables)
Needs a device because: the 24 pt slop, the 30%-of-width/600 pt-per-second commit thresholds, and
the spring-back are all tuned against real finger movement, not a scripted drag.

### setHTMLUnsafe swapping a message body from the canvas toggle or a verdict update — web anchor: n/a (native WKWebView API)
Needs a device because: `setHTMLUnsafe` is a real `WKWebView` content-process API with no Linux or
simulator-only substitute for confirming the swap is seamless (scroll, zoom and find state kept).

### Attachment long-press menus, `.eml` share, and the Event Details sheet — web anchor: n/a (native long-press, share sheet)
Needs a device because: long-press context menus and the system share sheet both need a real touch
and a real extension host process.

### Content inset under the glass bars in the reader — web anchor: n/a (native chrome)
Needs a device because: same as the list's inset check — translucent-material insets only render
on real glass.

### TextKit 2 draws NSTextList markers correctly (disc/circle/square, decimal, box/check) with consistent nested indent — web anchor: ui/src/components/compose (list rendering)
Needs a device because: `includesTextListMarkers` and marker glyph rendering are TextKit 2 drawing
behavior with no Linux equivalent.

### A tap in a checklist item's marker column toggles it — web anchor: tiptap task-list markup (ComposeHTMLSerializer's target shape)
Needs a device because: the tap target for the marker column versus the text itself needs a real
touch to confirm it doesn't also move the caret.

### Return/Backspace list semantics, and dictation/CJK input stays undisturbed — web anchor: n/a (native IME/dictation)
Needs a device because: marked text from dictation or CJK input only exists during a real IME
session; a simulator has no dictation and no CJK input method by default.

### Aa swaps keyboard and format panel, with active states and the 📎/🔗 menus — web anchor: ui/src/components/compose toolbar
Needs a device because: `inputAccessoryView` swapping and active-state highlighting are keyboard
and rendering behavior that needs the real keyboard to appear.

### HTML paste from Safari/Notes/Mail keeps structure; image paste goes inline; no stray paste banner — web anchor: n/a (native pasteboard)
Needs a device because: the system pasteboard's real HTML/webarchive representations, and the edit
menu's paste-banner heuristic, only exist with a real copy source.

### An inline image tap opens the size sheet; Remove is undoable — web anchor: ComposeImageAttachment (size menu: Small/Medium/Large/Full Width/Remove)
Needs a device because: `NSTextAttachment` tap handling inside a live `UITextView` needs real
touch dispatch through TextKit 2.

### The growing text view keeps the caret visible above the keyboard — web anchor: n/a (native caret/keyboard)
Needs a device because: `revealCaret` scrolling the sheet's enclosing `UIScrollView` as the
keyboard rises is real keyboard-avoidance behavior.

### Swipe-down on a dirty composer shows Save/Discard/Cancel; a clean one swipes away — web anchor: n/a (native sheet dismissal)
Needs a device because: `DismissAttemptObserver`'s presentation-controller delegate proxy only
intercepts a real interactive swipe-to-dismiss gesture.

### The recipient token field: separators commit, Backspace rhythm, blur commit, invalid-text styling, suggestions — web anchor: ui/src/components/compose recipient input
Needs a device because: a `UITextField`'s real keyboard input (Return, comma, semicolon,
Backspace-Backspace) and blur timing need actual typing to confirm.

### From grouped by account with 2+ accounts, hidden with one address — web anchor: ui/src/components/compose From picker
Needs a device because: the menu's actual grouped layout only renders in a live `Menu`.

### The Photos picker returns named JPEGs; `.fileImporter` reads files — web anchor: n/a (native pickers)
Needs a device because: `PHPickerViewController` and the system document picker are real iOS UI
with no simulator-free substitute, and the security-scoped resource access they grant only works
live.

### The quote card expands, its web-view height is measured, and its links stay inert — web anchor: ui/src/components/quote-card
Needs a device because: the collapsible `WKWebView`'s `contentSize` measurement
(`didFinish` + 400 ms) depends on real web-view layout timing.

### The undo-send capsule countdown, Undo restoring inline images/chips, and the "Too late" failure — web anchor: ui/src/components/undo-send-capsule (UNDO_TOAST_LABELS)
Needs a device because: the `TimelineView`-driven countdown and the race against a message
actually sending server-side both need real wall-clock time passing.

### Kill mid-compose, relaunch, "You have an unsent message · Open", Restore brings fields and files back — web anchor: ui/src/hooks/use-compose-recovery (or equivalent)
Needs a device because: `ComposeRecoveryStore`'s crash-recovery path requires a real process kill
and relaunch, not a screen navigation inside one running process.

### The sent toast, a staged send producing the capsule, and the failure banner — web anchor: ui/src/components/compose (submit flow)
Needs a device because: confirming the right toast/capsule/banner appears depends on a real
network round trip to the backend's outbox endpoint, including its timing (staged vs. immediate).

### composer-empty and composer-reply capture the loaded composer correctly — web anchor: n/a (fixture-mode screenshot)
Needs a device because: this is the rendered result of every item above; a single screenshot is
the cheapest confirmation that the composer as a whole reads right once a device is in hand.

### Notification banner decrypts while the phone is locked — web anchor: ui/src/hooks/use-push.ts
Needs a device because: the extension reads its content key from the shared Keychain group with
the phone locked, and only a real APNs push reaches it.

### Banners for alerts dismissed elsewhere are withdrawn by the next push — web anchor: src/mail_verdict/push/envelope.py (resolved ids)
Needs a device because: removing other delivered notifications from inside a notification service
extension only runs on a device.

### A silent read-sync push clears banners and sets the badge in the background — web anchor: src/mail_verdict/alerts/resolve.py (announce_alerts_dismissed)
Needs a device because: iOS delivers background pushes to a real device only, and throttles them.

### Mark as Read from a banner, with the app not running — web anchor: n/a (native notification action)
Needs a device because: a notification action launching the app in the background needs a real
push.

### `.scrollPosition(id:anchor:)` genuinely restores scroll position and collapse state on Mailboxes and Search — web anchor: n/a (native SwiftUI List scroll restoration)
Needs a device because: SwiftUI's own scroll-restoration behavior on `List` cannot be exercised
from the Linux toolchain, and the fixture sweep's single-screenshot-per-screen shape never
navigates away and back to test restoration.

### Spam Review's and Mailboxes' folder-row swipe actions and context menus — web anchor: ui/src/pages/spam-review-page.tsx, ui/src/components/mailboxes
Needs a device because: gesture shapes on a live `List`/`UITableView` row need real touch, the
same reasoning as the list's own swipe checks above.

### Int field's stepper range renders sanely — web anchor: ui/src/components/settings (generic category renderer)
Needs a device because: the generic settings renderer's `Stepper` over a wide integer range has
never been seen rendered; confirm the control itself handles it, not only that `Int.min...Int.max`
doesn't crash (bounded already, per the `ios` skill's own Stepper warning).

### JSON editor's `TextEditor` keyboard behavior and live validity check — web anchor: ui/src/components/settings (object/array field editor)
Needs a device because: a monospaced `TextEditor`'s real keyboard interaction and
`.fragmentsAllowed` validation leniency for a bare array/object edit need a live keyboard.

### Folder Order & Visibility's and Account Order's drag reorder — web anchor: ui/src/pages/account-settings (folder/account ordering)
Needs a device because: `EditButton`-driven drag reorder is a real-touch gesture, not exercised on
a simulator or device so far.

### Unified Views' per-folder multi-select Menu stays open per tap — web anchor: ui/src/components/unified-views-setup
Needs a device because: confirming a `Menu` + `Button` combination keeps the menu open across
repeated taps (rather than dismissing after the first) needs a live menu interaction.

### Confirmation dialog wording fits at a real device width — web anchor: ui/src/components/settings, ui/src/components/accounts (delete/confirm dialogs)
Needs a device because: text wrapping in a system alert is a rendering question only a real (or
simulator) screen width settles, and none of these were given more than a glance so far.

### Settings fields commit on focus loss and when the screen is left — web anchor: ui/src/components/settings (generic category renderer)
Needs a device because: a shared `FocusState` driving the blur-commit on every field kind, and
setting it to `nil` in `.onDisappear` to flush whatever was still focused when the screen was
popped, both depend on SwiftUI's real focus/teardown timing — not reproducible on the Linux
toolchain or the fixture screenshot sweep. Confirm: type into an int/decimal/text field, leave it
focused, and navigate back without pressing Return or the keyboard's Done — the edit must have
reached the server, not just the local text state.

### The legacy-group Keychain migration actually runs on a real install — web anchor: n/a (Keychain access group split)
Needs a device because: `PushKeychain.migrateFromLegacyGroupIfNeeded()`'s decision logic
(`MVKeychainMigrationPlan`) is package-tested, but the real `SecItemCopyMatching`/`SecItemAdd`
calls against two distinct access groups, and the credential's own explicit-group query finding
an item written before this change, both need a device already holding a pre-split install —
there is no such install to upgrade on a simulator or in fixture mode. Confirm on the existing
TestFlight install: after updating, push still delivers a real banner (not the generic fallback)
with no re-registration, and the stored backend credential is still read with no re-sign-in.

### The composer actually takes focus on open, and the keyboard raises — web anchor: ui/src/components/compose (autofocus on mount)
Needs a device because: `becomeFirstResponder()` deferred a turn past `makeUIView`, on a
`UIViewRepresentable` that is not yet attached to a window at the point it is called, is a timing
assumption the Linux toolchain and the fixture screenshot sweep (one static screenshot, no
keyboard) cannot exercise. Confirm: opening a new message raises the keyboard in To; opening a
reply or forward raises it in the body with the caret above the quote card, not inside it.

### Reader screenshots actually paint before being captured, and a plain message opens dark — web anchor: n/a (fixture-mode screenshot)
Needs a device because: the paint gate and the dark-canvas rule are covered by package tests and
by the sweep's own pass/fail, but nobody has looked at a resulting screenshot yet to confirm
reader-default no longer shows black and that a plain message's body is genuinely dark.

### The zoomed reader screenshot is genuinely pinched, not merely requested — web anchor: n/a (fixture-mode screenshot)
Needs a device because: a WKWebView's `setZoomScale` reportedly does not take; the entry now fails
the sweep instead of publishing a false positive, but whether it passes, or needs reading real
pinch-gesture zoom as its own device-only check instead, is unknown until that run happens.

### The quoted-text pill renders correctly in the reader and the composer — web anchor: n/a (fixture-mode screenshot)
Needs a device because: the CSS and SwiftUI changes compile but have not been seen; reader-default
and composer-reply are both fixture screenshots that would show it.

### tel:/sms: links and detected phone numbers actually hand off — web anchor: n/a (no equivalent web behavior)
Needs a device because: the confirmation alert and the `UIApplication.open` call are untestable
from the package, and a simulator's own telephony support may limit what the handoff looks like
there versus a real device.

### The native loading placeholder is visible and looks right on a cold launch — web anchor: n/a (no equivalent web behavior)
Needs a device because: the fixture sweep's own paint gate means no screenshot it takes will ever
show the placeholder; only watching a real cold launch confirms it replaces the black flash rather
than adding a visible flicker of its own.

### Account badges and contact photos appear on every row of a unified view — web anchor: ui/src/components/mail-list (account badge)
Needs a device because: the list controller now reconfigures a cell whenever what it draws changes,
including context that lands after the rows; the controller is UIKit and compiles only on macOS.
Confirm: open the Unified Inbox and Sent with grouping on and off, and leave and re-enter each —
every row shows its account badge, with no row missing it.

### A message opens without a visible wait — web anchor: n/a (native prefetch)
Needs a device because: the touch-down and on-screen prefetch, the synchronous first document from
the thread cache and the web view prewarm are timing on a real network and a real WebContent
process. Confirm: a row near the top opens with its content already drawn, with no spinner; paging
to a neighbour is instant; a message changed elsewhere still shows its current state after a beat.

### Select mode's bottom bar is Archive, Delete and Options — web anchor: n/a (reader bar parity)
Needs a device because: toolbar layout. Confirm: with rows ticked, the bar shows Archive and Delete
on the left and an Options menu on the right holding Mark, Star, Move to… and Junk (Not Junk in the
Junk folder); all three disable with nothing ticked.

### "Connecting…" only appears when the connection is genuinely down — web anchor: n/a
Needs a device because: scene-phase transitions and a real network. Confirm: switching away and
back never flashes "Connecting…"; airplane mode shows it after a few seconds and clears within a few
seconds of turning it off.

### Any message in a thread can be made the open one, and Reply answers it — web anchor: ui/src/components/mail/thread-message.tsx (Open this message), reading-pane.tsx (ReplyBox source)
Needs a device because: reader header layout and the web view control tap. Confirm: expanding an
older message offers "Open this message" (a small target icon beside its date); tapping it swaps
the primary message in place — the same row, no folder navigation, since the whole thread is
already loaded in one page — and the other messages collapse above it; Reply/Reply All/Forward
then target that message, not the newest, and it gets marked read. The web moves folder scope
because it re-fetches per message; ported as an in-page switch instead, since the iOS reader
already renders the full conversation as one document (`ConversationDocumentBuilder`) regardless
of which message is open. The web's own move of its per-message light/dark switch has no
equivalent here: iOS never had a labelled button for it — the switch is already scoped to
whichever message is primary, via the reader's Options menu.
