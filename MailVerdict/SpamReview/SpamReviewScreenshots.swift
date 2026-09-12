#if DEBUG

    /// Spam Review's own screenshot entries.
    enum SpamReviewScreenshots {
        static let entries: [MVScreenshotEntry] = [
            MVScreenshotEntry(id: "spam-review-queue", destination: .route(.spamReview))
        ]
    }

#endif
