#if DEBUG

    import Foundation

    /// Reads the launch arguments that drive a fixture-mode run.
    ///
    /// `xcrun simctl launch <bundle> <args...>` appends its trailing arguments to the process's
    /// own `argv`, so they show up in `ProcessInfo.arguments` exactly as passed — no Xcode
    /// scheme, no `UserDefaults` argument-domain magic, just the array every launch already has.
    /// Parsing that array directly keeps this testable with a plain `[String]` and keeps it
    /// working identically on Linux, where `UserDefaults` does not exist.
    public enum MVFixtureLaunch {

        static let modeFlag = "-MVFixtureMode"
        static let screenFlag = "-MVFixtureScreen"

        /// Whether the process was launched with `-MVFixtureMode`. The Mac workflow passes
        /// `-MVFixtureMode YES`; the trailing value is never read, only the flag's presence — the
        /// same "YES" Xcode's own launch-argument UI conventionally appends to a boolean flag.
        public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(modeFlag)
        }

        /// The id immediately following `-MVFixtureScreen`, if the launch named one — which
        /// `ScreenshotRegistry` entry (`MailVerdict/Shell/ScreenshotRegistry.swift`) the app
        /// should navigate to and report ready on, for the Mac workflow's per-screen sweep.
        /// `nil` when fixture mode is merely on with no specific screen asked for (the bridge's
        /// own `/screens` listing call, most concretely).
        public static func targetScreenId(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
            guard let flagIndex = arguments.firstIndex(of: screenFlag), flagIndex + 1 < arguments.count else {
                return nil
            }
            return arguments[flagIndex + 1]
        }
    }

#endif
