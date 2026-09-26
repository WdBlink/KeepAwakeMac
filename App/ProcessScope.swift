import Foundation
import AppKit

/// Watches a process by name and fires `onExit` when it stops running.
/// We use NSWorkspace's notification center; `NSWorkspace.didTerminateApplicationNotification`
/// fires when an app quits. We don't track spawned subprocesses — just the top-level
/// app the user named. Agent task completion is handled separately by AgentTask.
final class ProcessScope {

    private let processName: String
    private let onExit: () -> Void
    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?

    init(processName: String, onExit: @escaping () -> Void) {
        self.processName = processName
        self.onExit = onExit
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let app = info[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let self = self else { return }
            if let bn = app.bundleIdentifier, bn.lowercased().contains(self.processName.lowercased()) {
                self.onExit()
            } else if let name = app.localizedName, name.lowercased().contains(self.processName.lowercased()) {
                self.onExit()
            }
        }
        // Also poll as a backup — the notification isn't 100% reliable for all
        // process categories (e.g., agent processes may not register as apps).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkStillRunning()
        }
        checkStillRunning()
    }

    func stop() {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        pollTimer?.invalidate(); pollTimer = nil
    }

    private func checkStillRunning() {
        if !Self.isRunning(processName) { onExit() }
    }

    static func isRunning(_ processName: String) -> Bool {
        let target = processName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return NSWorkspace.shared.runningApplications.contains { app in
            (app.bundleIdentifier?.lowercased().contains(target) ?? false) ||
            (app.localizedName?.lowercased().contains(target) ?? false)
        }
    }
}
