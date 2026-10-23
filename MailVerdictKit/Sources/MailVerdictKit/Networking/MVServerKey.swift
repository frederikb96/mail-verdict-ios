import Foundation

/// A server URL as a file-name component, for everything kept on disk per server — so one server
/// always maps to the same files and two servers never share one.
enum MVServerKey {
    /// Case and a trailing slash are ignored.
    static func fileKey(_ serverURL: String) -> String {
        var normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasSuffix("/") { normalized.removeLast() }
        // FNV-1a, 64 bit: stable across launches and platforms, unlike `Hasher`.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
