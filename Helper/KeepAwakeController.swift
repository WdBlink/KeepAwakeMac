import Foundation
import IOKit

/// Accessed only on the helper's serial queue. The marker survives helper crashes.
final class KeepAwakeController {
    private let marker: URL
    private let run: ([String]) throws -> String
    private let readEnabled: () throws -> Bool
    private let lidClosed: () -> Bool?
    private var displaySleepRequested = false
    private(set) var owner: pid_t?
    private var deadline: TimeInterval = 0

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
        guard owner != nil || FileManager.default.fileExists(atPath: marker.path) else { return }
        try setEnabled(false)
        if FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
        owner = nil
        deadline = 0
        displaySleepRequested = false
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

    /// Called by the existing one-second lease timer, only during our session.
    @discardableResult
    func sleepDisplayIfLidClosed() throws -> Bool {
        guard owner != nil, let closed = lidClosed() else { return false }
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
