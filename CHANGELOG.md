# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.4] - 2026-09-15

### Added

- Any message in a thread can be made the open one: an expanded older message gets an "Open this
  message" control that makes it the one Reply, Reply All and Forward answer.

### Fixed

- Collapsing an account or the Unified section in Mailboxes actually collapses it now — tapping
  the chevron previously did nothing, since the collapse state lived outside SwiftUI's own
  Observation tracking.

## [0.1.3] - 2026-09-13

### Changed

- Opening a message is faster: conversations are fetched as soon as a finger lands on a row and for
  the rows on screen, a recently read one opens from memory and is refreshed behind it, and the
  reader's web view is warmed up at launch.
- Lists open with their account badges, contact photos and title already in place when they have
  been opened before, and load that data in parallel rather than one request after another.
- Select mode's bottom bar matches the reader: Archive and Delete, with Mark, Star, Move and Junk
  under Options.

### Fixed

- Unified views: the account badge on each avatar, and contact photos, now appear on every row —
  rows drawn before that data arrived kept showing without it.
- The list's quick filter no longer shows "Could not filter: Cancelled." while typing, and its
  results show the matched words bold instead of wrapped in `**`.
- "Connecting…" no longer lingers after returning to the app: the live connection closes in the
  background and reconnects immediately on return, and a reconnect that finishes within a few
  seconds is not shown at all. A quiet but healthy connection is no longer torn down every minute.

## [0.1.2] - 2026-09-12

### Fixed

- Mailboxes: tapping a folder or Unified View row anywhere opens it — a tap on its name or icon
  did nothing, and only the empty space beside them worked.

## [0.1.1] - 2026-09-12

### Fixed

- The message list: folders with no saved order now follow the web's order — Inbox, Drafts, Sent,
  Archive, Junk, Trash, then everything else alphabetically.
- Mailboxes folder and Unified View rows, and the folder checklists in Search, Notifications and
  the Move picker, look like native rows instead of tinted buttons.
- Select mode: the title reads "N Selected" instead of truncating, and the swipe Options sheet
  opens large enough to show every action without scrolling.
- Reader: a plain message with no colours of its own opens dark in dark mode instead of as a white
  block; a message that sets its own colours stays light, and the Dark/Light toggle is unchanged.
- Reader: folded quotes show a native "•••" disclosure instead of an underlined link; the
  composer's quote card matches.
- Reader: a tapped or detected phone number can be handed off to Phone or Messages.
- Reader: a brief loading placeholder replaces what could otherwise be a black flash while a
  message opens, and the body now follows the system text size like the rest of the reader.
- Settings: fields save when you leave them or the screen, and number fields get a keyboard Done
  key.
- Unified Views: folders are grouped under their accounts, with proper folder names.
- Accounts: account detail stays correct if the account is removed elsewhere, and names the sync
  method in words.
- Composer: the cursor starts in To for a new message, and in the body for a reply or forward.
- Keychain items are scoped to least privilege; an existing install migrates automatically on
  first launch.
- The Connect screen warns before sending a credential over plain http.

## [0.1.0] - 2026-09-12

### Added

- Project scaffold: `MailVerdictKit` local Swift package, `MailVerdict` app target, CI workflows,
  signing lanes, and the debug bridge.
- The message list: swipe right to archive; swipe left to delete, or a short swipe for Options
  and Delete (in Trash, Delete Forever asks first); long-press for the Options menu with a
  preview — built, not yet confirmed by hand on a device.
- Select mode: Select, Select All over the whole folder, a two-finger swipe to tick rows, and
  bulk Mark, Move, Junk, Archive and Trash with Undo.
- An unread filter, an in-folder quick filter with "Search all mail for …", and a Group by
  Conversation toggle.
- Mark All as Read and Empty Folder… in the list's ••• menu.
- New mail arriving while you read further down never moves the list; a "N New Messages" button
  takes you to it.
- Going back from a message returns you to your place in the list, and the app reopens where you
  left each list — built and unit-tested, not yet confirmed by hand on a device.
- Move to… lists your recently used folders first.
- Reader: swipe between messages like Photos, pinch to zoom, and a bottom bar of Archive, Delete
  and Options.
- Reader: every message renders sanitized in its own isolated view with no message script; remote
  images stay blocked unless the sender is allowed.
- Reader: Find in Message, attachments in Quick Look with Share, and calendar invitations with
  Accept, Tentative and Decline.
- Composer: new message, reply, reply all, forward and drafts in one native sheet, with rich text
  (bold, italic, underline, strikethrough, lists, checklists, quotes, code blocks, links) and no
  markdown.
- Composer: recipients with contact autocomplete, Cc/Bcc, and a From picker that follows each
  account's identities.
- Composer: attachments from Photos and Files, pasted images inline with a size menu, forwarded
  attachments carried along.
- Composer: the quoted original as a collapsible, removable card; drafts reopen with their quote.
- Undo send: a countdown capsule whose Undo reopens the message with everything restored.
- Crash recovery: an unsent message, attachments included, is offered back after the app is
  closed or killed.
- New-mail notifications on iPhone through the push relay, end-to-end encrypted. The banner's
  sender and subject are decrypted on the phone; the relay and Apple see ciphertext only.
- Mark as Read on the notification. Tapping a notification opens the message.
- New Mail Notifications settings: permission, device name, New Mail/System channels, folder
  scope per account, other devices with Remove, and Send Test Notification.
- Notifications read or dismissed elsewhere disappear from the phone, and the app icon badge
  follows the server's count.
- Mailboxes: unified and per-account folder sections, account health and sync status, folder
  actions (Mark All Read, Empty Folder, New/Delete Folder), and a banner when an account's outbox
  can't send.
- Search: text and semantic search across accounts and folders, with filters for fields,
  strictness, sort, account, folder and received-date range.
- Spam Review: a queue of messages pending a spam/not-spam decision, swipe or thumbs up/down to
  decide, and Accept All/Reject All.
- Notifications screen: a Mail tab and a System tab for alerts and cross-account notifications,
  with Dismiss All and swipe to dismiss or acknowledge.
- Settings: an appearance picker (System/Light/Dark), account order, every backend setting
  category editable on the phone, AI provider keys (Anthropic, OpenAI), and Unified Views
  management.
- Accounts: a list and detail screen with sync status, add/edit accounts, Folder Order &
  Visibility, Image Exceptions, and Sending Identities with a default picker.
