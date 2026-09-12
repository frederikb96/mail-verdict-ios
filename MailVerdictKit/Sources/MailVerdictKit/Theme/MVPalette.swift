#if canImport(SwiftUI)

    import SwiftUI

    /// Every colour token a SwiftUI screen in this app uses — views never write a colour literal,
    /// they read a case here. Chrome uses iOS system semantics directly (`.primary`,
    /// `.secondaryLabel`, Liquid Glass bars); this type is only for MailVerdict's own marks, the
    /// ones the web carries its own tokens for (UX design §5).
    ///
    /// `messageCanvas` and the find-highlight colours are the reader's own CSS-level tokens
    /// (`emailStyles`/`mark.search-match`), not `Color` values — they stay in `Reader/`, that
    /// block's own files, since nothing here ever renders inside the message `WKWebView`.
    public enum MVPalette {
        /// The web's primary is a neutral near-black; a neutral tint here would make buttons
        /// read as plain text rather than controls, so this follows iOS Mail instead.
        public static let tint = Color.blue

        public static let unreadDot = Color(light: "#0ea5e9", dark: "#38bdf8")

        /// The IMAP `\Flagged` bit, labelled "Star" on iOS (row 38 note 4) rather than the web's
        /// "Flag" wording — same bit, different name and colour than either the web's own yellow
        /// star or iOS Mail's orange flag idiom.
        public static let star = Color.yellow

        public static let destructive = Color.red
        public static let spamMark = Color.red

        public static let imageBannerBackground = Color(light: "#f59e0b", dark: "#fbbf24").opacity(0.1)
        public static let imageBannerText = Color(light: "#b45309", dark: "#fbbf24")

        public static let deadBannerBackground = Color.red.opacity(0.1)
        public static let deadBannerText = Color.red

        /// `avatarColorHex(for:)` (Formatting/SenderFormatting.swift) is the source of truth for
        /// which of the twelve palette colours a given identity gets — this only turns that hex
        /// string into a `Color` for a view to use.
        public static func avatarColor(for identity: String) -> Color {
            Color(hex: avatarColorHex(for: identity))
        }
    }

    extension Color {
        /// A light/dark pair expressed as hex, resolved via `UITraitCollection` rather than two
        /// asset-catalog entries — this package has no asset catalog of its own to put them in.
        init(light: String, dark: String) {
            #if canImport(UIKit)
                self = Color(
                    uiColor: UIColor { traits in
                        UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) ?? .clear
                    }
                )
            #else
                self = Color(hex: light)
            #endif
        }

        /// `"#rrggbb"`, the avatar palette and image-banner tokens' own shape — parsed by hand
        /// rather than pulled in a dependency for six lines of arithmetic.
        init(hex: String) {
            let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            var value: UInt64 = 0
            Scanner(string: trimmed).scanHexInt64(&value)
            let r = Double((value >> 16) & 0xFF) / 255
            let g = Double((value >> 8) & 0xFF) / 255
            let b = Double(value & 0xFF) / 255
            self = Color(red: r, green: g, blue: b)
        }
    }

    #if canImport(UIKit)
        import UIKit

        extension UIColor {
            convenience init?(hex: String) {
                let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                var value: UInt64 = 0
                guard Scanner(string: trimmed).scanHexInt64(&value) else { return nil }
                self.init(
                    red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1
                )
            }
        }
    #endif

#endif
