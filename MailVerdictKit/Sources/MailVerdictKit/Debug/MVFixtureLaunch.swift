#if DEBUG

    import Foundation

    /// Reads the launch arguments that drive a fixture-mode run.
    ///
    /// `xcrun simctl launch <bundle> <args...>` appends its trailing arguments to the process's
    /// own `argv`, so they show up in `ProcessInfo.arguments` exactly as passed — no Xcode
    /// scheme, no `UserDefaults` argument-domain magic, just the array every launch already has.
    /// Parsing that array directly keeps this testable with a plain `[String]` and keeps it
    /// working identically on Linux, where `UserDefaults` does not exist.
    ///
    /// Only the mode flag exists yet — there are no feature screens for a fixture run to seed a
    /// route or a state into. Whatever adds the first screen to the fixture sweep is the place to
    /// add the matching flag here, growing one per screen from there.
    public enum MVFixtureLaunch {

        static let modeFlag = "-MVFixtureMode"

        /// Whether the process was launched with `-MVFixtureMode`.
        public static func isEnabled(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
            arguments.contains(modeFlag)
        }
    }

#endif
