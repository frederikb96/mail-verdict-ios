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

### The reader's actions reach the list at once — web anchor: ui/src/hooks/use-mails.ts (useMailAction)
Needs a device because: the reader closing onto the list and the list controller applying the
change are UIKit transitions. Confirm: open the only message in a folder and Archive — the reader
closes onto a list that is already empty, with no row flashing and disappearing; star or mark a
message unread in the reader and go Back — the row already shows it; Move to… from the reader slides
on to the next message and the moved row is gone from the list.

### Actions wait out a bad connection — web anchor: ui/src/hooks/use-mails.ts (useMailAction)
Needs a device because: `NWPathMonitor`, a real network dropping, app relaunch and the row and
reader chrome. Confirm: in airplane mode, archive a message and star another — the archived row
leaves at once, the starred row shows a small spinner after a moment and the list subtitle reads
"1 action waiting for the network"; turn the network back on — both reach the server within a few
seconds with nothing left waiting. Archive offline, quit the app from the switcher, relaunch online
— the message stays out of the list and is archived on the server. Archive offline and tap Undo —
the row comes back and nothing reaches the server. Move a message to a folder that was deleted on
another client — the row comes back with a red mark and an error toast offering Retry. The reader's
subtitle reads "Waiting for the network" while its message's change is waiting. Row height does not
change for either mark.

### Actions that need a decision, and actions finishing in the background — web anchor: ui/src/components/layout/actions-indicator.tsx
Needs a device because: the bottom capsule and confirmation dialog, `beginBackgroundTask`, and the
subtitle chrome. Confirm: archive a message, lock the phone within a second — the archive reaches
the server (check on the web) without unlocking. Move a message to a folder another client just
deleted — "1 failed" appears in a capsule at the bottom of the list; Retry resends, Discard puts the
row back. In airplane mode, archive a message and leave the phone for over an hour, then turn the
network on — nothing is sent, the capsule reads "1 action not sent", Send Now archives it and Discard
brings the row back. An idle reader shows no empty subtitle line under its title.

### Folders are not emptied or deleted under unsent actions — web anchor: ui/src/components/sidebar/folder-manage-dialog.tsx
Needs a device because: the Mailboxes context menu and toast. Confirm: in airplane mode, move a
message out of a folder, then long-press that folder — Empty Folder… and Delete Folder… each show an
error toast instead of their confirmation; back online, once the move has gone, both confirmations
appear as usual.

### Live stream reconnects sanely on a weak connection — server anchor: GET /api/events
Needs a device because: only a real mobile link accepts a connection and drops it again. Confirm:
with the app open on mobile data, move between coverage and none (or leave and rejoin a network)
several times, then count `GET /api/events` in the server's own log for that period — attempts are
seconds apart and back off, never hundreds in a few seconds, and the list reconnects and shows new
mail afterwards without a relaunch.


### Glacier storage: every screen built, needs a real device pass — web anchor: ui/src/components/layout/app-sidebar.tsx, ui/src/components/mail/move-to-folder-popover.tsx, ui/src/components/accounts/accounts-page.tsx
Needs a device because: package tests prove the logic, but nothing on Linux renders a SwiftUI
view or a WKWebView. Every piece is built and unit-tested at the package level: Mailboxes' sidebar
shows the glacier row with its own snowflake icon and offers neither "New Folder Inside…" nor
"Delete Folder…" on it; the Move picker (swipe sheet, context menu, select-mode bulk move, and the
reader's own "Move to…") offers the glacier as a target and confirms with the count and "leaves
the mail server for good" before sending the move — and a message just moved in is never shown
under its old id afterward, since the server hands that id to a genuinely new row rather than
relocating the old one and neither the single-message nor the bulk response carries the new id
back, so the list simply drops the row from view instead of guessing at an id it does not have,
the same as moving to any folder the current view is not showing; permanently deleting a glaciered
message (swipe, context menu, and the reader's own bottom bar and Options, all already reading
Delete Forever instead of Delete the same way a Trash message does) confirms with "this is the
only copy" and sends the `confirm` flag the server requires for it — proved end to end against a
recorded request body, not only against the action-set logic; the same is now true of Select mode
within the glacier's own list — mark read/unread, star/unstar, move, archive and delete all
resolve a glacier selection server-side, by id and by the glacier as scope, so Select is offered
there again, with only the junk toggle held back (spam rulings on glaciered mail are still
refused) — Mark All as Read is offered too, since it only ever needs a timestamp from the
selection-count endpoint, never the count itself; Empty Folder… stays withheld specifically for
the glacier, because that endpoint's own count still resolves against the live mail table alone
and would always read 0, which the bulk request's own count check would then refuse against
whatever actually exists — revisit once that endpoint gets a glacier branch too; account settings
has the switch, the automatic-sweep-days field (now captioned with what a number means and that
blank means moving only by hand), editable only once the account exists, with the same
leave/clear/set shape trash and junk retention already use; Account Detail's own summary line
reads "On, sweeps after N days" / "On, manual only" / "Off"; the sync toggle's optimistic update
no longer drops the glacier fields (a real bug, covered by a package test that was watched failing
first); opening the glacier's own folder shows its mail list and lets a glaciered message open in
the reader, where it carries a provenance banner (with a corrected snowflake icon — an earlier
version merged lucide's twelve subpaths into one path string, which silently broke every subpath's
positioning past the first) naming where it used to live, its body and attachment still render.
Every fix in this and the previous three rounds was watched failing first; a whole-corpus
fixture-coverage test proves every fixture route the glacier reader page calls is actually served,
and the vendored API contract is synced to the server's current commit. Registered for the
screenshot sweep: `list-move-picker` (the picker with the glacier row visible), `list-glacier` (the
glacier's own list, Select and Mark All as Read offered, Empty Folder… withheld),
`list-glacier-select-mode` (a selection ticked within it, the bulk toolbar and Options menu
visible), `account-edit-glacier` (the edit sheet, scrolled to the switch, the days field and its
new caption), `reader-glacier` (a glaciered message with an attachment, provenance banner, and
Delete Forever in the bottom bar); the existing `mailboxes` and `account-detail` entries also show
a glacier-enabled account/folder now. Confirm: enable a glacier on an account (through the web UI
or the app's own edit sheet), open Mailboxes for that account and see the Glacier row with its
snowflake icon and no rename/delete in its menu; open the move picker on a message, choose
Glacier, and confirm the alert names the count and says the mail leaves the server for good, both
for a single message and for a multi-select bulk move, and both from the list and from the
reader's own Options "Move to…", and confirm the moved message is no longer shown anywhere under
its old id; move a message into the glacier, then open it and permanently delete it, confirming
the "only copy" alert appears and the message is actually gone afterward; open the glacier's own
folder, confirm Select and Mark All as Read work (tick a few rows, use the bulk toolbar and
Options menu — archive, delete, move, mark read/unread, star/unstar), confirm the junk toggle is
absent from the Options menu there, and confirm there is still no Empty Folder… in its "…" menu;
open a glaciered message and confirm the provenance banner (snowflake icon rendering correctly,
not as a scattered fragment), its attachment, and that the bottom bar reads Delete Forever; open
Search, tap the Folders chip for that account and confirm "Glacier" is offered as a scope (needs
no app code — the server already returns it, so this is a smoke check of the wiring, not new
logic); open account settings, scroll to (or confirm the screenshot sweep already scrolled to) the
Glacier section, and see the switch, the days field and its caption, matching what the web form
shows, and confirm saving it round-trips.

### One live stream for the whole app, not one per rebuild — server anchor: GET /api/events
Needs a device because: only a real session — moving between screens, leaving and returning to the
app, a push arriving — rebuilds the shell often enough for a second connection to accumulate, and
the extra ones are invisible on screen. Confirm: use the app normally for a few minutes, then count
`GET /api/events` and `GET /api/accounts/<id>/folders` in the server's own log over that period —
single figures, never hundreds inside one second — and check that the mail list keeps loading while
an action is waiting for the network.

### Tapping a link offers opening in the app or in the system browser, in one tap — web anchor: n/a (native confirmation dialog)
Needs a device because: `confirmationDialog` layout and the resulting handoff can only be judged on
device. Confirm: tap a link in a message and see one dialog with "Open in App" and "Open in
Browser" (no browser named), no second tap needed for either; "Open in App" opens the in-app
browser view as before, "Open in Browser" leaves the app for whatever browser is set as the
system default (not necessarily Safari).

### Restoring a glaciered message needs its own confirmation everywhere it can start — web anchor: `ui/src/components/mail/reading-pane.tsx`'s `pendingGlacierRestore`
Needs a device because: `GlacierRestoreWarning`'s wiring (the row's swipe sheet and context menu
Archive, the reader's Archive and its own "Move to…", the list's select-mode Archive/Trash/"Move
to…", and a new bulk "Delete Forever" for a glacier-scoped selection) is package logic already
covered by `MailVerdictKitTests`, each watched failing first, but every alert's actual title,
wording and button placement is unverified until seen on a real screen. Confirm: with a message
already in the glacier, swipe it and choose Archive from the sheet — the alert must appear before
anything happens, naming the restore, not perform it straight away; open it in the reader and press
Archive, then its own "Move to…" to an ordinary folder — same gate, same wording; in select mode,
tick a glacier-folder selection and use the bottom bar's Archive and Trash, and the Options menu's
"Move to…" to an ordinary folder — each confirms before acting; still in select mode, confirm the
Options menu now also offers a destructive "Delete Forever" for a glacier-scoped selection, naming
the count and the "only copy" wording, and that confirming it actually removes the selection for
good. Undo/Discard on a glacier move (`MVIntentLedger.reversal(of:)`) is also package-tested
(watched failing first) but worth a device pass too: move a message into the glacier, let the
action fail once (turn the network off at the right moment) so it backs off, then Discard it from
the attention banner — the message must not silently reappear outside the glacier; a reversed
glacier move would be an unconfirmed restore, exactly what this whole entry exists to prevent.

### Moving an order's mail to another order — web anchor: ui/src/components/orders/order-picker-dialog.tsx
Needs a device because: the target picker and its network write aren't ported to the phone this
release, only remove-from-this-order is. Confirm: from an order's mail row, move it to another
order and check both orders' mail counts and identifiers updated correctly, and the source order's
summary is queued for a rewrite.

### Merging two orders — web anchor: ui/src/components/orders/order-picker-dialog.tsx
Needs a device because: the merge target picker isn't ported to the phone this release. Confirm:
merge one order into another and check the target's mail count and identifiers combine correctly
and the source order disappears with none of its mail touched.

### The "Look through recent mail…" catch-up dialog — web anchor: ui/src/components/accounts/accounts-page.tsx
Needs a device because: it triggers real, billed model calls against a live account, which a
screenshot sweep must never do. Confirm: for an account with orders bundling on, run a dry run and
check the reported count against the real mailbox, then run it for real and watch the orders queue
drain to zero.

### A Wallet pass document opens in Quick Look, not Wallet — web anchor: ui/src/components/orders/order-detail.tsx
Needs a device because: `PKAddPassesViewController` needs a physical pass and a real Wallet app;
Quick Look substitutes for it this release and never offers "Add to Wallet". Confirm: open a
`.pkpass` document from an order and check whether Quick Look's own pass preview is enough, or
whether the missing "Add to Wallet" affordance is worth a dedicated pass sheet later.

### Scroll position holds after Back from an opened mail — web anchor: ui/src/components/orders/order-detail.tsx
Needs a device because: whether `NavigationStack` keeps the detail view's scroll position across a
push/pop is a claim about UIKit's own view lifecycle, not verifiable from a screenshot. Confirm:
open a mail from the middle of a long order, back out, and check the list is still scrolled to
where it was rather than reset to the top.

### Orders list: swipes, long-press menu and filter field — web anchor: ui/src/components/orders/orders-page.tsx, ui/src/lib/order-actions.ts
Needs a device because: swipe, long-press and the search field's behaviour inside a `List` are
gesture and UIKit-lifecycle claims. Confirm: on the orders list, swipe a row from the left edge
to close or reopen it and from the right edge to favorite or unfavorite it (each shows a toast and
the row updates in place); long-press a row and check the menu offers Favorite, Close, Seal,
Rewrite Summary and Delete Order… with "Add no more mail" under Seal (a two-line menu item is the
part to look at); pull the filter field down, type, and check the list narrows after a pause and
shows "No matching orders" when nothing fits; pick Favorites from the filter menu and check an
empty list reads "No favorites yet".

### Merging an order from the list and detail menus — web anchor: ui/src/components/orders/order-actions.tsx
Needs a device because: merge still has no target picker on the phone, so the shared order menu
omits the web's "Merge into another order…" entry. Confirm: once the picker exists, add the entry
to `OrderActionSet` and check both menus and the merge confirmation.

### "Add Rule…" in the reader's Options menu — web anchor: ui/src/components/mail/add-rule-dialog.tsx
Needs a device because: it runs a real, billed model call against the server's configured
provider, and the sheet's behaviour (keyboard, cancel on dismiss, swipe-down while a request runs)
is UIKit presentation. Confirm: open a live mail, Options → Add Rule…, type a sentence and propose;
check one section per affected rule (New / Changed / Moved / Removed, each with its "Now" and
"Proposed" text) — ask for something touching two rules at once, such as splitting one rule by
sender — the "Would have caught N of your last M mails" line and its examples, then Accept and look
at the rules in the web Pipeline page. Also confirm that dismissing the sheet while "Working out a
change…" shows stops the request (the server log shows no further
model call), that Accept cannot be dismissed mid-write, that a rule edited elsewhere in between
gives "Rules changed meanwhile — ask again.", and that the item is absent for a glaciered mail.
