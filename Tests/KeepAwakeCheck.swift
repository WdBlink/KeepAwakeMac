import Foundation

@main
struct KeepAwakeCheck {
    static func expectFailure(_ call: () throws -> Void) {
        do { try call(); fatalError("Expected failure") } catch { }
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = directory.appendingPathComponent("active")
        defer { try? FileManager.default.removeItem(at: directory) }
        var enabled = false
        var failDisable = false
        var failEnable = false
        var failRead = false
        var delayStateChange = false
        var staleReads = 0
        let readEnabled: () throws -> Bool = {
            if failRead { throw KeepAwakeController.Failure("Simulated read error") }
            if staleReads > 0 { staleReads -= 1; return !enabled }
            return enabled
        }
        var lidClosed: Bool? = false
        var lidReads = 0
        var displaySleeps = 0
        var failDisplaySleep = false
        let run: ([String]) throws -> String = { arguments in
            if arguments == ["displaysleepnow"] {
                precondition(enabled, "Display sleep must leave system keep-awake enabled")
                if failDisplaySleep { throw KeepAwakeController.Failure("Simulated display error") }
                displaySleeps += 1
                return ""
            }
            precondition(arguments == ["-a", "disablesleep", "1"] || arguments == ["-a", "disablesleep", "0"])
            staleReads = delayStateChange ? 3 : 0
            if arguments.last == "1" {
                precondition(FileManager.default.fileExists(atPath: marker.path), "Recovery marker must precede the write")
                enabled = true
                if failEnable { throw KeepAwakeController.Failure("Simulated write error") }
            } else {
                if failDisable { throw KeepAwakeController.Failure("Simulated reset error") }
                enabled = false
            }
            return ""
        }
        let controller = KeepAwakeController(marker: marker, run: run, readEnabled: readEnabled, lidClosed: {
            lidReads += 1
            return lidClosed
        })
        try controller.sleepDisplayIfLidClosed()
        precondition(lidReads == 0, "Do not monitor the lid outside an active session")
        failRead = true
        expectFailure { try controller.enable(for: 123) }
        precondition(controller.owner == nil && !FileManager.default.fileExists(atPath: marker.path))
        failRead = false
        try controller.enable(for: 123, now: 100)
        precondition(enabled)
        expectFailure { try controller.enable(for: 456) }
        expectFailure { try controller.disable(for: 456) }
        precondition(controller.owner == 123 && enabled)
        let state = try controller.currentState(for: 123, now: 110)
        precondition(state)
        failRead = true
        expectFailure { _ = try controller.currentState(for: 123, now: 111) }
        precondition(controller.owner == 123 && enabled, "Unknown state must not be interpreted as disabled")
        failRead = false
        try controller.expireIfNeeded(now: 125)
        precondition(enabled, "Heartbeat must renew the lease")
        try controller.expireIfNeeded(now: 131)
        precondition(!enabled && controller.owner == nil)
        precondition(!FileManager.default.fileExists(atPath: marker.path))
        print("PASS: direct state reads without subprocesses, unknown state, ownership, heartbeat renewal, and lease expiry")

        try controller.enable(for: 123, now: 200)
        try controller.sleepDisplayIfLidClosed()
        lidClosed = nil
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 0, "Open or unknown lid state must not blank the screen")
        lidClosed = true
        try controller.sleepDisplayIfLidClosed()
        try controller.sleepDisplayIfLidClosed()
        lidClosed = nil
        try controller.sleepDisplayIfLidClosed()
        lidClosed = true
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 1 && enabled, "Sleep the display once per closure, keeping the system awake")
        lidClosed = false
        try controller.sleepDisplayIfLidClosed()
        lidClosed = true
        failDisplaySleep = true
        expectFailure { try controller.sleepDisplayIfLidClosed() }
        failDisplaySleep = false
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 2, "A failed display request must be retried")
        try controller.disable()
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 2, "Disabled sessions must not control the display")
        try controller.enable(for: 123, now: 300)
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 3, "Enabling with the lid already closed must sleep the display")
        try controller.expireIfNeeded(now: 321)
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 3 && !enabled)
        print("PASS: lid-close display sleep, open/unknown state, retry, re-enable, and expiry")

        try controller.enable(for: 123, now: 400)
        lidClosed = true
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 4, "A closed lid blanks the display once")
        controller.setDisplayHold(true)
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 4, "The tool must not request a lid blank while the switch holds the screen")
        controller.setDisplayHold(false)
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 5, "A stale latch must not suppress the next closure")
        // The lid, not the hold, decides: with the hold off, an open lid takes the
        // latch-reset branch, so the next closure blanks again. That branch is
        // only reached when lidClosed() is actually consulted.
        lidClosed = false
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 5, "An open lid must not blank the screen")
        lidClosed = true
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 6, "Reopening the lid must reset the latch so the next closure blanks")
        try controller.disable()
        precondition(!enabled && controller.owner == nil)
        print("PASS: the screen-awake switch stops the lid blank, plus latch reset and the open-lid branch")

        // The reviews' regression: 屏幕常亮 on, 合盖保活 off and on again, lid closed.
        // The hold belongs to the switch, not to the lid session, so the helper
        // must still refuse to blank the screen.
        lidClosed = true
        controller.setDisplayHold(true, from: 123)
        try controller.enable(for: 123, now: 600)
        try controller.disable()
        try controller.enable(for: 123, now: 700)
        try controller.expireIfNeeded(now: 725)
        try controller.enable(for: 123, now: 800)
        precondition(controller.displayHoldOwner == 123 && enabled,
                     "Only the app's own transition may end the hold, not a lid session")
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 6,
                     "A lid-mode cycle must not re-arm displaysleepnow under an active screen-awake hold")
        // Only the app's own transition, or its process exiting, ends the hold.
        controller.setDisplayHold(false)
        try controller.sleepDisplayIfLidClosed()
        precondition(displaySleeps == 7, "Releasing the hold hands the lid rule back immediately")
        try controller.disable()
        precondition(!enabled && !FileManager.default.fileExists(atPath: marker.path))

        // The ordering the reviews found: the lease timer is armed at helper
        // launch and ticks unconditionally, so a blank could land the moment a
        // session starts — before the user has finished turning 屏幕常亮 on, and
        // an explicit displaysleepnow is not undone by the assertion they are
        // about to take. A new session must not blank during its settling window.
        lidClosed = true
        try controller.enable(for: 123, now: 1000)
        for tick in 0..<Int(KeepAwakeController.settlingWindow) {
            try controller.sleepDisplayIfLidClosed(now: 1000 + Double(tick))
        }
        precondition(displaySleeps == 7,
                     "The helper must not blank before the app has had a chance to state the hold")
        controller.setDisplayHold(true)
        try controller.sleepDisplayIfLidClosed(now: 1000 + KeepAwakeController.settlingWindow - 0.1)
        precondition(displaySleeps == 7, "A hold that arrives inside the window still wins")
        // The window is a settling delay, not an exemption: once it has passed
        // the lid rule resumes on its own, so OUT-3 still holds.
        controller.setDisplayHold(false)
        try controller.sleepDisplayIfLidClosed(now: 1000 + KeepAwakeController.settlingWindow)
        precondition(displaySleeps == 8, "Once settled, a closed lid blanks again as before")
        try controller.disable()
        print("PASS: a new lid session waits out its settling window before it may blank the screen")

        // A hold left behind by an app that no longer exists must not suppress
        // the closed-lid rule for the next launch. A live one must survive.
        controller.setDisplayHold(true, from: getpid())
        try controller.disable()
        precondition(controller.displayHoldOwner == getpid(),
                     "A session-less disable must not drop a live screen-awake hold")
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        controller.setDisplayHold(true, from: gone.processIdentifier)
        try controller.disable()
        precondition(controller.displayHoldOwner == nil,
                     "A hold whose app has exited must not outlive it")
        print("PASS: the screen-awake hold survives disable, lease expiry, and re-enable")

        enabled = true
        expectFailure { try controller.enable(for: 123) }
        try controller.disable()
        precondition(enabled, "Do not clear another tool's setting")
        enabled = false
        try controller.enable(for: 123)
        let restarted = KeepAwakeController(marker: marker, run: run, readEnabled: readEnabled)
        try restarted.recover()
        precondition(!enabled && !FileManager.default.fileExists(atPath: marker.path))
        failEnable = true
        expectFailure { try restarted.enable(for: 123) }
        precondition(!enabled, "A failed enable must roll back even if the write took effect")
        failEnable = false
        try restarted.enable(for: 123, now: 200)
        failDisable = true
        expectFailure { try restarted.disable() }
        precondition(enabled && FileManager.default.fileExists(atPath: marker.path))
        failDisable = false
        try restarted.expireIfNeeded(now: 221)
        precondition(!enabled)
        print("PASS: other-tool isolation, crash recovery, rollback, and retry after reset failure")

        delayStateChange = true
        try restarted.enable(for: 123)
        precondition(enabled && staleReads == 0)
        try restarted.disable()
        precondition(!enabled && staleReads == 0)
        delayStateChange = false
        print("PASS: enable and disable wait for delayed kernel state changes")

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        expectFailure { try restarted.recover() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        print("PASS: an unsafe recovery directory is rejected")

        func trip(_ percent: Int?, _ onAC: Bool?, _ thermal: ProcessInfo.ThermalState = .nominal,
                  chargingOnly: Bool = false) -> Bool {
            Watchdog.stopReason(percent: percent, onAC: onAC, thermal: thermal,
                                batteryFloor: 20, thermalAutoStop: true,
                                chargingOnly: chargingOnly) != nil
        }
        precondition(!trip(80, true))
        precondition(trip(20, true))
        precondition(trip(nil, nil))
        precondition(trip(80, false, chargingOnly: true))
        precondition(!trip(80, false))
        precondition(trip(80, true, .critical))
        print("PASS: battery threshold, missing power data, unplug, and thermal guards")

        // The old three-second command deadline incorrectly rejected this response.
        let slow = Process()
        slow.executableURL = URL(fileURLWithPath: "/bin/sleep")
        slow.arguments = ["3.2"]
        _ = try KeepAwakeController.runPowerCommand(slow)
        let stuck = Process()
        stuck.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stuck.arguments = ["30"]
        let start = ProcessInfo.processInfo.systemUptime
        expectFailure { _ = try KeepAwakeController.runPowerCommand(stuck, timeout: 0.1) }
        precondition(!stuck.isRunning && ProcessInfo.processInfo.systemUptime - start < 2,
                     "Timeout must stop and reap the command before returning")
        precondition(AppConstants.helperRequestTimeout > 3 * (AppConstants.powerCommandTimeout + 1) + 2 * AppConstants.powerStateTimeout,
                     "XPC must allow queued display sleep, enable, and rollback to finish")
        print("PASS: slow power response, bounded timeout cleanup, and coordinated XPC deadline")
    }
}
