/// Whether an account's `error` state is a terminal failure or still retrying — an account that
/// has synced at least once before erroring is PostIMAP's own IDLE/periodic-fallback loop still
/// running in the background, not dead; one that has never completed a first sync never connected
/// at all. A direct port of the web's `accountConnectionState`.
public enum MVAccountConnectionState: Equatable, Sendable {
    case ok
    case retrying
    case neverConnected

    public static func classify(state: String, lastFullSync: Bool) -> MVAccountConnectionState {
        guard state == "error" else { return .ok }
        return lastFullSync ? .retrying : .neverConnected
    }
}
