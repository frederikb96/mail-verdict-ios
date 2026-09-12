#if canImport(SwiftUI)

    import SwiftUI

    /// Dynamic Type text styles for the list row and reader chrome — UX design §5. No fixed point
    /// sizes anywhere: every value here is a system text style, so Dynamic Type follows through
    /// automatically.
    public enum MVTypography {
        public static func listSenderFont(isUnread: Bool) -> Font {
            isUnread ? .body.weight(.semibold) : .body
        }

        public static func listDateColor(isUnread: Bool) -> Color {
            isUnread ? .primary : .secondary
        }

        public static func listSubjectFont(isUnread: Bool) -> Font {
            .subheadline.weight(isUnread ? .bold : .regular)
        }

        public static func listSubjectColor(isUnread: Bool) -> Color {
            isUnread ? .primary : .secondary
        }

        public static let listPreview = Font.subheadline

        public static let readerSubject = Font.title2.weight(.bold)
        public static let readerHeaderName = Font.headline
        public static let readerSecondary = Font.subheadline
    }

#endif
