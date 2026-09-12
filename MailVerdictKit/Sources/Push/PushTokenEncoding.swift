import Foundation

public enum PushTokenEncoding {
    /// The APNs device token as lowercase hex, the form the relay accepts. Spelled out byte by byte:
    /// a token encoded any other way still registers without complaint, and notifications then
    /// simply never arrive.
    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}
