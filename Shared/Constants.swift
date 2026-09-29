import Foundation

enum AppConstants {
    static let mainAppBundleID = "com.local.KeepAwakeMac"
    static let helperBundleID = "com.local.KeepAwakeMac.Helper"

    /// XPC service name used to talk to the privileged helper.
    static let helperMachServiceName = "com.local.KeepAwakeMac.Helper"

    /// Path to `pmset` — the system binary we shell out to. Hard-coded because
    /// `/usr/sbin` is in the default PATH for root-launched processes but not for
    /// double-clicked launchd helpers in some sandboxed configurations.
    static let pmsetPath = "/usr/bin/pmset"
    static let powerCommandTimeout: TimeInterval = 8
    static let powerStateTimeout: TimeInterval = 1

    /// Bumped whenever the app↔helper contract changes. A helper that answers
    /// `currentState` but does not know `protocolInfo` is a pre-v2 build: it
    /// never learned about `setDisplayHold`, so it will keep issuing
    /// `pmset displaysleepnow` no matter what the app believes. `HelperService`
    /// compares this against the running daemon and re-registers on a mismatch.
    static let helperProtocolVersion = 2
    // Allow a queued display operation, an enable, and its rollback to finish.
    static let helperRequestTimeout: TimeInterval = 3 * (powerCommandTimeout + 1) + 2 * powerStateTimeout + 3
}
