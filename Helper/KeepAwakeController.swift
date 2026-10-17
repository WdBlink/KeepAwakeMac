import Foundation
import IOKit

/// Accessed only on the helper's serial queue. The marker survives helper crashes.
final class KeepAwakeController {
    private let marker: URL
    private let run: ([String]) throws -> String
    private let readEnabled: () throws -> Bool
    private let lidClosed: () -> Bool?
    private var displaySleepRequested = false
    private var displayHold = false
    private(set) var displayHoldOwner: pid_t?
    private(set) var owner: pid_t?
    private var deadline: TimeInterval = 0
    private var sessionStartedAt: TimeInterval = 0

    /// How long a new session may not blank the screen. See `sleepDisplayIfLidClosed`.
    static let settlingWindow: TimeInterval = 5

    init(marker: URL = URL(fileURLWithPath: "/Library/Application Support/KeepAwakeMac/session-active"),
         run: @escaping ([String]) throws -> String = KeepAwakeController.runPmset,
         readEnabled: @escaping () throws -> Bool = KeepAwakeController.readSystemSleepDisabled,
         lidClosed: @escaping () -> Bool? = KeepAwakeController.readLidClosed) {
        self.marker = marker
        self.run = run
        self.readEnabled = readEnabled
        self.lidClosed = lidClosed
    }

    func recover() throws {
        if FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().path) {
            try validateMarkerDirectory()
        }
        if FileManager.default.fileExists(atPath: marker.path) { try disable() }
    }

    func enable(for pid: pid_t, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard owner == nil || owner == pid else {
            throw Failure("Another KeepAwakeMac session is already active.")
        }
        if owner == nil {
            guard try !readEnabled() else {
                throw Failure("Sleep is already disabled by another tool. Turn that tool off first.")
            }
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try validateMarkerDirectory()
            try Data("active\n".utf8).write(to: marker, options: .atomic)
            sessionStartedAt = now
        }
        owner = pid
        deadline = now + 20
        do {
            try setEnabled(true)
        } catch {
            try? disable()
            throw error
        }
    }

    func disable(for pid: pid_t? = nil) throws {
        if let pid = pid, let owner = owner, owner != pid {
            throw Failure("The active session belongs to another KeepAwakeMac process.")
        }
        guard owner != nil || FileManager.default.fileExists(atPath: marker.path) else {
            // No session, but a hold can still be set: 屏幕常亮 alone. Clear it
            // here only if its app is gone, so a crashed or killed app cannot
            // leave the closed-lid rule suppressed for the next launch.
            if let pid = displayHoldOwner, kill(pid, 0) != 0 { setDisplayHold(false) }
            return
        }
        try setEnabled(false)
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
        owner = nil
        deadline = 0
        displaySleepRequested = false
        sessionStartedAt = 0
        // displayHold deliberately survives: it belongs to the app's screen-awake
        // switch, not to this lid session. Clearing it here would re-arm
        // displaysleepnow while 屏幕常亮 is still on. The owning pid's exit watch
        // and the app's own transitions are what clear it.
    }

    func currentState(for pid: pid_t, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Bool {
        guard owner == pid else { return false }
        guard try readEnabled() else {
            try disable()
            return false
        }
        deadline = now + 20
        return true
    }

    func expireIfNeeded(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        if owner != nil && now >= deadline { try disable() }
    }

    private func setEnabled(_ enabled: Bool) throws {
        _ = try run(["-a", "disablesleep", enabled ? "1" : "0"])
        // pmset can return before powerd applies the setting to the kernel.
        let deadline = ProcessInfo.processInfo.systemUptime + AppConstants.powerStateTimeout
        while try readEnabled() != enabled {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Failure(enabled ? "macOS did not enable lid-close keep-awake." : "macOS did not restore sleep.")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// The app's explicit screen-awake switch outranks the lid-close rule.
    /// Turning the hold on clears the latch: a closure that already blanked the
    /// screen must not suppress the next blank once the switch goes off again.
    /// `from` is the requesting process, so a crash cannot leave the hold set.
    @discardableResult
    func setDisplayHold(_ held: Bool, from pid: pid_t? = nil) -> Bool {
        // A hold's owner can release it across lid sessions; nil is helper cleanup.
        if let pid, let currentOwner = displayHoldOwner ?? owner, currentOwner != pid { return false }
        if held {
            displaySleepRequested = false
            displayHold = true
            displayHoldOwner = pid
        } else {
            displayHold = false
            displayHoldOwner = nil
        }
        return true
    }

    /// Called by the existing one-second lease timer, only during our session.
    ///
    /// A new session does not blank the display until its settling window has
    /// passed. The lease timer starts at helper launch and ticks unconditionally,
    /// so without the window the first tick after `enable()` blanks the screen —
    /// before the user has finished opening the menu and turning 屏幕常亮 on, and
    /// an explicit `displaysleepnow` is not undone by the assertion they are
    /// about to take. The window is not a guess at when the app answers: the app
    /// may already have said `hold = true`, which wins immediately, well inside
    /// the window.
    @discardableResult
    func sleepDisplayIfLidClosed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Bool {
        guard owner != nil, !displayHold else { return false }
        guard now - sessionStartedAt >= Self.settlingWindow else { return false }
        guard let closed = lidClosed() else { return false }
        guard closed else {
            displaySleepRequested = false
            return false
        }
        guard !displaySleepRequested else { return false }
        // Explicit display sleep also works when an app prevents idle display sleep.
        // ponytail: once per closure; add wake monitoring if external input must be suppressed too.
        _ = try run(["displaysleepnow"])
        displaySleepRequested = true
        return true
    }

    static func readLidClosed() -> Bool? {
        readRootDomainBool("AppleClamshellState")
    }

    static func readSystemSleepDisabled() throws -> Bool {
        // Read only the flag we need. `pmset -g` also waits on unrelated power
        // settings and assertions, and used to spawn a process every heartbeat.
        guard let enabled = readRootDomainBool("SleepDisabled") else {
            throw Failure("Could not read the system sleep setting. Try again.")
        }
        return enabled
    }

    private static func readRootDomainBool(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func validateMarkerDirectory() throws {
        var metadata = stat()
        guard lstat(marker.deletingLastPathComponent().path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw Failure("The recovery directory has unsafe ownership or permissions.")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func runPmset(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AppConstants.pmsetPath)
        process.arguments = arguments
        do { return try runPowerCommand(process) }
        catch {
            NSLog("pmset %@ failed: %@", arguments.joined(separator: " "), error.localizedDescription)
            throw error
        }
    }

    static func runPowerCommand(_ process: Process,
                                timeout: TimeInterval = AppConstants.powerCommandTimeout) throws -> String {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // The helper ignores SIGTERM, which children can inherit. Kill the
            // timed-out command and allow its exit callback to run before rollback.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = finished.wait(timeout: .now() + 1)
            throw Failure("macOS power settings did not respond within \(Int(timeout)) seconds. Try again.")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure("Could not update power settings: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }
}
