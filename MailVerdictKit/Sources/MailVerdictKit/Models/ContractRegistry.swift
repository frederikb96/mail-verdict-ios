/// Every `ContractModel` conformance in this package, so `ContractTests` (Linux, free) can check
/// each one against the vendored snapshot without being told about a new model by hand.
///
/// `Tooling/check-contract-registry.sh` greps the source for `: ContractModel` / `, ContractModel`
/// conformances and diffs them against this list — a model added without a matching registration
/// fails CI rather than silently going unchecked; one removed here without deleting the model
/// does too.
public enum ContractRegistry {
    // A list of metatypes, read-only after this file loads — `nonisolated(unsafe)` says exactly
    // that, since `[any ContractModel.Type]` itself cannot be `Sendable`.
    nonisolated(unsafe) public static let all: [any ContractModel.Type] = [
        // Message.swift
        TagResponse.self,
        AttachmentSummary.self,
        VerdictResponse.self,
        MessageSummary.self,
        MessageListResponse.self,
        MessageLocation.self,
        MessageDetail.self,
        ThreadResponse.self,
        MessageQuoteResponse.self,
        MessageActionRequest.self,
        MessageActionResponse.self,
        // BulkAction.swift
        BulkActionScope.self,
        BulkActionRequest.self,
        BulkActionSource.self,
        BulkActionResponse.self,
        SelectionSnapshotResponse.self,
        // Search.swift
        SearchResult.self,
        SearchResponse.self,
        SearchDateBoundsResponse.self,
        SemanticSearchResponse.self,
        // Account.swift
        AccountResponse.self,
        AccountCreateRequest.self,
        AccountUpdateRequest.self,
        SyncStatusResponse.self,
        // Folder.swift
        FolderResponse.self,
        FolderPrefsUpdate.self,
        FolderCreateRequest.self,
        FolderOrderItem.self,
        FolderOrderResponse.self,
        FolderOrderUpdate.self,
        // SpamReview.swift
        FeedbackRequest.self,
        FeedbackResponse.self,
        SpamReviewItem.self,
        SpamReviewListResponse.self,
        // Notification.swift
        NotificationResponse.self,
        NotificationCountResponse.self,
        // Identity.swift
        IdentityCreate.self,
        IdentityUpdate.self,
        IdentityResponse.self,
        // Outbox.swift (OutboxCreateRequest excluded — see its own doc comment)
        OutboxAttachmentSummary.self,
        OutboxResponse.self,
        PendingSendAttachmentSummary.self,
        PendingSendResponse.self,
        // Unified.swift
        UnifiedFolderSource.self,
        UnifiedFolderResponse.self,
        UnifiedViewCreate.self,
        UnifiedViewUpdate.self,
        UnifiedViewResponse.self,
        EmojiUpdate.self,
        UnifiedFolderOrderResponse.self,
        UnifiedFolderOrderUpdate.self,
        // AccountOrder.swift
        AccountOrderResponse.self,
        AccountOrderUpdate.self,
        // ImageException.swift
        ImageExceptionCreate.self,
        ImageExceptionResponse.self,
        // Contact.swift
        ContactSearchHitOut.self,
        ContactPhotoIndexEntry.self,
        ContactPhotoIndexResponse.self,
        // Calendar.swift
        EventAttendee.self,
        EventOrganizer.self,
        OwnReply.self,
        EventReminder.self,
        EventInstance.self,
        RespondRequest.self,
        ImportInvitationRequest.self,
        Invitation.self,
        MVCalendar.self,
        // Alert.swift
        AlertResponse.self,
        AlertUnseenCountResponse.self,
        VapidPublicKeyResponse.self,
        PushSubscriptionKeys.self,
        PushSubscriptionCreate.self,
        PushSubscriptionUpdate.self,
        PushSubscriptionResponse.self,
        NativePushConfigResponse.self,
        NativeSubscriptionCreate.self,
        AlertLookupRequest.self,
        AlertBadgeResponse.self,
    ]
}
