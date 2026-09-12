#if DEBUG

    /// Mailboxes' own screenshot entries — the Mac workflow's sweep reaches each of these by
    /// relaunching with `-MVFixtureScreen <id>`. `mailboxes-fixture-row` needs no navigation
    /// (Mailboxes is already the root) and no prepare step: the stub renders the fixture row
    /// unconditionally.
    enum MailboxesScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "mailboxes-fixture-row", destination: .root)
        ]
    }

#endif
