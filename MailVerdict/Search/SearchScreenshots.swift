#if DEBUG

    /// Search's own screenshot entries.
    enum SearchScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "search-with-results", destination: .route(.search(initialQuery: "invoice")))
        ]
    }

#endif
