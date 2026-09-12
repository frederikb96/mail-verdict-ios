import Foundation

/// What reading a page marks read — ports of the reading pane's auto-read effect and
/// `useMarkConversationRead` in the web's `use-mails.ts`.
public enum ReaderReadPolicy {

    /// The opened message is marked read when its page settles, except a draft (about to be
    /// edited, not read) and the one message someone explicitly marked unread while looking at it
    /// — otherwise the reader would undo that action the moment it lands.
    public static func shouldMarkRead(_ message: MessageDetail, explicitlyUnreadId: UUID?) -> Bool {
        !message.isDraft && !message.isSeen && message.id != explicitlyUnreadId
    }

    /// A row grouped by conversation counts every unread message of its thread, so reading it
    /// marks the rest of the thread read too — within the row's own folders, and leaving out the
    /// opened message, which `shouldMarkRead` already covers.
    public static func conversationIdsToMarkRead(
        thread: [MessageDetail], openedId: UUID, folderIds: [UUID]
    ) -> [UUID] {
        let scope = Set(folderIds)
        return thread.filter { scope.contains($0.folderId) && !$0.isSeen && $0.id != openedId }.map(\.id)
    }
}
