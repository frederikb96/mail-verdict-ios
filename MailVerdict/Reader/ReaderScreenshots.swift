#if DEBUG

    /// The reader's own screenshot entries — empty until S2 replaces the stub with the real
    /// pager and adds one entry per state worth capturing (default zoom, zoomed, Options menu).
    enum ReaderScreenshots {
        static let entries: [MVScreenshotEntry] = []
    }

#endif
