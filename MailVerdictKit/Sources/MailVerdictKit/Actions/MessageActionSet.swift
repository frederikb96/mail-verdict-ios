import Foundation

/// Where the Options set is being shown — the three surfaces UX design §2.3 names: the row
/// short-swipe sheet, the row long-press context menu, and the reader's own Options button menu.
public enum MVMessageActionSurface: Sendable, Equatable {
    case swipeSheet
    case contextMenu
    case readerOptionsMenu
}

public enum MVMessageActionSource: Sendable, Equatable {
    case list
    case reader
    case search
    case spamReview
}

/// The verdict fields the Verdict action group needs — `nil` on `MVMessageContext.verdict` means
/// the message carries no verdict at all, which is what makes the whole group absent.
public struct MVMessageVerdictContext: Sendable, Equatable {
    public let isSpam: Bool
    public let modelUsed: String?

    public init(isSpam: Bool, modelUsed: String?) {
        self.isSpam = isSpam
        self.modelUsed = modelUsed
    }
}

/// Everything `MessageActionSet.actions(for:)` needs to decide which actions apply — deliberately
/// just state, no identifiers: the caller already knows which message this is about, and building
/// the request (and resolving "the thread's latest message" in threaded mode) is `MailActionService`'s
/// job, not this type's.
public struct MVMessageContext: Sendable, Equatable {
    public let surface: MVMessageActionSurface
    public let source: MVMessageActionSource
    public let isRead: Bool
    public let isStarred: Bool
    public let isInTrash: Bool
    public let isInJunk: Bool
    public let verdict: MVMessageVerdictContext?
    public let hasBlockedImages: Bool
    public let canvasIsDark: Bool

    public init(
        surface: MVMessageActionSurface, source: MVMessageActionSource, isRead: Bool,
        isStarred: Bool, isInTrash: Bool, isInJunk: Bool,
        verdict: MVMessageVerdictContext? = nil, hasBlockedImages: Bool = false,
        canvasIsDark: Bool = false
    ) {
        self.surface = surface
        self.source = source
        self.isRead = isRead
        self.isStarred = isStarred
        self.isInTrash = isInTrash
        self.isInJunk = isInJunk
        self.verdict = verdict
        self.hasBlockedImages = hasBlockedImages
        self.canvasIsDark = canvasIsDark
    }
}

/// One Options action — the UI layer owns its label and SF Symbol (`Theme/MVSymbols.swift`);
/// this is only ever the decision of which apply.
public enum MVMessageUIAction: Sendable, Equatable {
    case reply
    case replyAll
    case forward
    case confirmVerdict
    case correctVerdict
    case markRead
    case markUnread
    case star
    case unstar
    case moveTo
    case moveToJunk
    case notJunk
    case archive
    case findInMessage
    case loadImagesOnce
    case alwaysLoadFromSender
    case alwaysLoadFromDomain
    case darkBackground
    case lightBackground
    case shareMessageFile
    case showInFolder
    case delete
    case deleteForever
}

public struct MVMessageActionGroup: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case respond, verdict, state, tools, destructive
    }

    public let kind: Kind
    public let actions: [MVMessageUIAction]

    public init(kind: Kind, actions: [MVMessageUIAction]) {
        self.kind = kind
        self.actions = actions
    }
}

/// The one list every Options surface renders from — a sheet, a `UIMenu` and a SwiftUI `Menu`
/// alike build off `actions(for:)`, so the three can never drift into showing different sets for
/// the same message.
public enum MessageActionSet {
    public static func actions(for context: MVMessageContext) -> [MVMessageActionGroup] {
        var groups: [MVMessageActionGroup] = [
            MVMessageActionGroup(kind: .respond, actions: [.reply, .replyAll, .forward])
        ]

        if context.verdict != nil {
            groups.append(MVMessageActionGroup(kind: .verdict, actions: [.confirmVerdict, .correctVerdict]))
        }

        var state: [MVMessageUIAction] = [
            context.isRead ? .markUnread : .markRead,
            context.isStarred ? .unstar : .star,
            .moveTo,
            context.isInJunk ? .notJunk : .moveToJunk,
        ]
        // Archive exists in the swipe and context menu only — the reader has it in its own
        // bottom bar, so the Options menu there never repeats it.
        if context.surface != .readerOptionsMenu {
            state.append(.archive)
        }
        groups.append(MVMessageActionGroup(kind: .state, actions: state))

        // Tools is reader-only.
        if context.surface == .readerOptionsMenu {
            var tools: [MVMessageUIAction] = [.findInMessage]
            if context.hasBlockedImages {
                tools.append(contentsOf: [.loadImagesOnce, .alwaysLoadFromSender, .alwaysLoadFromDomain])
            }
            tools.append(context.canvasIsDark ? .lightBackground : .darkBackground)
            tools.append(.shareMessageFile)
            if context.source == .search || context.source == .spamReview {
                tools.append(.showInFolder)
            }
            groups.append(MVMessageActionGroup(kind: .tools, actions: tools))
        }

        // Destructive appears in the swipe sheet and context menu as its own group; the reader's
        // Options menu only ever gains the single Delete Forever item, and only in Trash — its
        // ordinary Delete already lives in the bottom bar.
        if context.surface != .readerOptionsMenu {
            groups.append(
                MVMessageActionGroup(
                    kind: .destructive, actions: [context.isInTrash ? .deleteForever : .delete]
                )
            )
        } else if context.isInTrash {
            groups.append(MVMessageActionGroup(kind: .destructive, actions: [.deleteForever]))
        }

        return groups
    }
}
