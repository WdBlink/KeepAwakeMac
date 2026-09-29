import Foundation
import ServiceManagement

// Uses an anonymous XPC service; never runs pmset or changes power settings.
private final class TestHelper: NSObject, KAMHelperProtocol, NSXPCListenerDelegate {
    enum Behavior { case success, reject, disconnect, silent, lateReply }
    var behavior: Behavior = .success
    var replyDelay: TimeInterval = 0.4
    var displayHold: Bool?
    var rejectDisplayHold = false
    /// What `currentState` claims. The app's heartbeat asks once per tick and
    /// tears the session down on a negative answer, so a test that wants to
    /// watch the heartbeat renew anything has to say the session is still up.
    var reportsEnabled = false
    /// Seconds the hold relay stalls. Set it above the client timeout to model a
    /// wedged helper queue, and to order two racing relays deterministically.
    var displayHoldDelay: TimeInterval = 0
    /// The contract this double claims to implement. An older number stands in
    /// for a daemon built before `setDisplayHold` existed.
    var protocolReply: Int = AppConstants.helperProtocolVersion
    /// Relay order as the helper received it, independent of when each reply
    /// came back. `displayHold` records the last one that completed.
    var holds: [Bool] = []
    /// When set, a hold relay parks here until the test signals it. A duration
    /// cannot express "the helper has not answered yet" — that is a fact about
    /// what the test has observed, not about the clock — and a check that has to
    /// inspect the app mid-relay needs the former.
    var holdGate: DispatchSemaphore?

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: KAMHelperProtocol.self)
        connection.exportedObject = self
        if behavior == .disconnect {
            connection.invalidate()
            return false
        }
        connection.resume()
        return true
    }

    func enableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void) {
        switch behavior {
        case .success: reply(true, nil)
        case .reject: reply(false, "Test helper rejected the operation")
        case .silent, .disconnect: break
        case .lateReply:
            DispatchQueue.global().asyncAfter(deadline: .now() + replyDelay) { reply(true, nil) }
        }
    }

    func disableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void) {
        enableLidOpenKeepAwake(reply: reply)
    }

    func currentState(reply: @escaping (Bool, String?) -> Void) { reply(reportsEnabled, nil) }

    func setDisplayHold(_ held: Bool, reply: @escaping (Bool, String?) -> Void) {
        guard !rejectDisplayHold else { reply(false, "Test helper rejected the display hold"); return }
        holds.append(held)
        if let gate = holdGate {
            gate.wait()
            displayHold = held
            reply(true, nil)
            return
        }
        guard displayHoldDelay > 0 else {
            displayHold = held
            reply(true, nil)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + displayHoldDelay) {
            self.displayHold = held
            reply(true, nil)
        }
    }

    func protocolInfo(reply: @escaping (Int) -> Void) { reply(protocolReply) }
}

/// A helper double backed by the real `KeepAwakeController`, so the app half and
/// the power half of the fix are exercised through one XPC seam instead of two
/// unrelated test objects that happen to agree.
private final class ControllerHelper: NSObject, KAMHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "check.controller-helper")
    private let marker: URL
    private(set) var displaySleeps = 0
    private(set) var sessions = 0
    private(set) var holds: [Bool] = []
    private(set) var systemSleepDisabled = false
    var lidClosed: Bool? = true
    /// A fake uptime, advanced one second per lease tick, so the helper's
    /// settling window is exercised without waiting five real seconds.
    private(set) var now: TimeInterval = 0

    override init() {
        marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-controller-\(UUID().uuidString)")
        super.init()
    }

    private lazy var controller: KeepAwakeController = {
        let marker = self.marker
        return KeepAwakeController(marker: marker, run: { [unowned self] arguments in
            if arguments == ["displaysleepnow"] { displaySleeps += 1; return "" }
            precondition(arguments == ["-a", "disablesleep", "1"] || arguments == ["-a", "disablesleep", "0"],
                         "Unexpected power command: \(arguments)")
            if arguments.last == "1" {
                precondition(FileManager.default.fileExists(atPath: marker.path),
                             "Recovery marker must precede the write")
            }
            systemSleepDisabled = arguments.last == "1"
            return ""
        }, readEnabled: { [unowned self] in systemSleepDisabled },
           lidClosed: { [unowned self] in lidClosed })
    }()

    func cleanUp() { try? FileManager.default.removeItem(at: marker.deletingLastPathComponent()) }

    /// One iteration of the real helper's one-second lease timer.
    func leaseTick() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.now += 1
                try? self.controller.expireIfNeeded(now: self.now)
                _ = try? self.controller.sleepDisplayIfLidClosed(now: self.now)
                done.resume()
            }
        }
    }

    func ticks(_ count: Int) async {
        for _ in 0..<count { await leaseTick() }
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: KAMHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func enableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            do {
                try self.controller.enable(for: ProcessInfo.processInfo.processIdentifier, now: self.now)
                self.sessions += 1
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func disableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            do { try self.controller.disable(for: ProcessInfo.processInfo.processIdentifier); reply(true, nil) }
            catch { reply(false, error.localizedDescription) }
        }
    }

    func currentState(reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            reply((try? self.controller.currentState(for: ProcessInfo.processInfo.processIdentifier,
                                                     now: self.now)) == true, nil)
        }
    }

    func setDisplayHold(_ held: Bool, reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            self.holds.append(held)
            self.controller.setDisplayHold(held, from: ProcessInfo.processInfo.processIdentifier)
            reply(true, nil)
        }
    }

    func protocolInfo(reply: @escaping (Int) -> Void) {
        queue.async { reply(AppConstants.helperProtocolVersion) }
    }
}

@main
struct HelperClientCheck {
    @MainActor
    static func checkServiceRegistration() async throws {
        let suite = "KeepAwakeMac.registration-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var status: SMAppService.Status = .enabled // Stale, but still approved.
        var registrations = 0
        var removals = 0
        var needsApproval = false
        var failRemoval = false
        var failRegistration = false
        func prepare(_ identity: String) async throws {
            try await HelperService.prepare(registrationID: identity, defaults: defaults,
                status: { status }, register: {
                    if failRegistration { throw HelperService.ServiceError("Test registration failure") }
                    registrations += 1
                    status = needsApproval ? .requiresApproval : .enabled
                }, unregister: {
                    if failRemoval { throw HelperService.ServiceError("Test removal failure") }
                    removals += 1
                    status = .notRegistered
                })
        }
        try await prepare("build-1")
        try await prepare("build-1")
        precondition(registrations == 1 && removals == 1, "Repair stale registration only once")
        try await prepare("build-2")
        precondition(registrations == 2 && removals == 2, "An updated signature must refresh registration")
        failRemoval = true
        do { try await prepare("build-3"); fatalError("Removal failure was hidden") } catch {}
        precondition(defaults.string(forKey: "helperRegistrationIdentity") == "build-2")
        failRemoval = false; failRegistration = true
        do { try await prepare("build-3"); fatalError("Registration failure was hidden") } catch {}
        precondition(defaults.string(forKey: "helperRegistrationIdentity") == "build-2")
        failRegistration = false; needsApproval = true
        for _ in 0..<2 {
            do { try await prepare("build-3"); fatalError("Approval was skipped") }
            catch is HelperService.ApprovalRequired {} // Keep approval pending across retries.
        }
        precondition(registrations == 3 && removals == 3, "Pending approval must not cause re-registration")
        status = .enabled
        needsApproval = false
        try await prepare("build-3")
        precondition(registrations == 3 && removals == 3)

        // A daemon launched from an older bundle keeps running under KeepAlive,
        // and the stored identity describes a bundle, not a binary. An in-place
        // update that only swaps the bundle leaves that daemon answering the old
        // contract — with no `setDisplayHold`, so it keeps blanking the screen the
        // app believes it is holding. The version is the only signal that sees it.
        func negotiate(_ identity: String, _ protocolVersion: Int?) async throws {
            try await HelperService.prepare(registrationID: identity, defaults: defaults,
                status: { status }, register: {
                    if failRegistration { throw HelperService.ServiceError("Test registration failure") }
                    registrations += 1
                    status = needsApproval ? .requiresApproval : .enabled
                }, unregister: {
                    if failRemoval { throw HelperService.ServiceError("Test removal failure") }
                    removals += 1
                    status = .notRegistered
                }, runningProtocol: { protocolVersion })
        }
        try await negotiate("build-3", 1)
        precondition(registrations == 4 && removals == 4,
                     "A helper from before setDisplayHold must be replaced, not tolerated")
        try await negotiate("build-3", AppConstants.helperProtocolVersion)
        precondition(registrations == 4 && removals == 4,
                     "A matching helper must not be re-registered on every call")
        try await negotiate("build-3", nil)
        precondition(registrations == 5 && removals == 5,
                     "An unreachable helper cannot be trusted to match this contract")
        print("PASS: stale service repair, build changes, helper version skew, failure retry, and pending approval")
    }

    static func expectError<T>(_ fragment: String,
                               _ call: () async throws -> T) async {
        do {
            _ = try await call()
            fatalError("Expected error containing: \(fragment)")
        } catch {
            precondition(error.localizedDescription.contains(fragment), "Unexpected error: \(error)")
        }
    }

    @MainActor
    static func main() async throws {
        try await checkServiceRegistration()
        // Also bounds failures of the regression itself (e.g. a leaked continuation).
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: XPC call or UI remained stuck\n", stderr)
            exit(1)
        }

        let missing = PrivilegedHelperClient(timeout: 1) {
            NSXPCConnection(machServiceName: "com.local.KeepAwakeMac.check.\(UUID().uuidString)",
                            options: .privileged)
        }
        await expectError("unavailable") { try await missing.enable() }
        await expectError("unavailable") { try await missing.disable() }
        await expectError("unavailable") { try await missing.isCurrentlyEnabled() }
        await expectError("unavailable") { try await missing.setDisplayHold(true) }
        await expectError("unavailable") { try await missing.enable() }
        // A daemon that predates the call rejects the selector outright, which is
        // the only way the app can tell "no helper" from "an old helper".
        await expectError("unavailable") { try await missing.protocolVersion() }
        print("PASS: missing service errors for enable, disable, state query, display hold, version, and retry")

        let helper = TestHelper()
        let listener = NSXPCListener.anonymous()
        listener.delegate = helper
        listener.resume()
        defer { listener.invalidate() }
        let client = PrivilegedHelperClient(timeout: 0.15) {
            NSXPCConnection(listenerEndpoint: listener.endpoint)
        }

        let enabled = try await client.enable()
        precondition(enabled)
        let disabled = try await client.disable()
        precondition(disabled)
        let state = try await client.isCurrentlyEnabled()
        precondition(!state, "A false state is a valid reply, not a transport failure")
        helper.behavior = .reject
        await expectError("Test helper rejected") { try await client.enable() }
        helper.behavior = .disconnect
        await expectError("unavailable") { try await client.enable() }
        helper.behavior = .silent
        await expectError("did not respond") { try await client.enable() }
        helper.behavior = .lateReply
        await expectError("did not respond") { try await client.enable() }
        try await Task.sleep(nanoseconds: 500_000_000)
        helper.behavior = .success
        let retried = try await client.enable()
        precondition(retried)
        let heldOn = try await client.setDisplayHold(true)
        precondition(heldOn && helper.displayHold == true)
        let heldOff = try await client.setDisplayHold(false)
        precondition(heldOff && helper.displayHold == false)
        let version = try await client.protocolVersion()
        precondition(version == AppConstants.helperProtocolVersion)
        helper.protocolReply = 1
        let staleVersion = try await client.protocolVersion()
        precondition(staleVersion == 1, "A stale daemon must be able to report the contract it implements")
        helper.protocolReply = AppConstants.helperProtocolVersion
        print("PASS: replies, rejection, disconnect, timeout, late reply, recovery, hold relay, and version")

        // Two clicks that overlap in flight. Each XPC call owns its own connection
        // and NSXPC does not order messages across connections, so without the
        // busy guard the last *reply* wins rather than the last click, and the
        // helper ends up believing the opposite of the menu. The off-relay is made
        // the slow one so the inversion is deterministic rather than lucky.
        helper.holds = []; helper.displayHold = nil
        helper.displayHoldDelay = 0.5
        let overlap = AppState(helper: client, prepareHelper: {},
                               display: DisplayAwake(create: { _ in 1 }, release: { _ in }),
                               powerSnapshot: { (100, true) })
        overlap.triggerMode = .manual; overlap.batteryFloorPercent = 5; overlap.thermalAutoStopEnabled = false
        let turningOff = Task { await overlap.setScreenAwake(false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await overlap.setScreenAwake(true)
        await turningOff.value
        helper.displayHoldDelay = 0
        precondition(helper.holds.count == 1 && helper.holds == [false],
                     "A click refused mid-flight must not also send a second relay")
        precondition(!overlap.screenAwake && overlap.screenChanging == false,
                     "The refused click must leave the switch where the accepted one put it")
        // Now the accepted click is the one that moves the hold, and the helper
        // has to end up agreeing with it.
        await overlap.setScreenAwake(true)
        precondition(helper.displayHold == true && overlap.screenAwake)
        await overlap.setScreenAwake(false)
        precondition(helper.displayHold == false && !overlap.screenAwake)
        print("PASS: overlapping screen-awake clicks leave the helper agreeing with the switch")

        // The switch does not depend on the helper, so turning it off must not
        // wait for one. Park the off-relay inside the helper and the screen has
        // to be released already: a slow XPC round trip must not pin a screen
        // the user just turned off, nor leave the menu reading
        // 「正在关闭，请稍候…」 until the helper answers.
        helper.holds = []; helper.displayHold = nil
        let gate = DispatchSemaphore(value: 0)
        var live = 0
        var nextID: UInt32 = 0
        let prompt = AppState(helper: client, prepareHelper: {},
                              display: DisplayAwake(create: { _ in nextID += 1; live += 1; return nextID },
                                                   release: { _ in live -= 1 }),
                              powerSnapshot: { (100, true) })
        prompt.triggerMode = .manual; prompt.batteryFloorPercent = 5; prompt.thermalAutoStopEnabled = false
        await prompt.setScreenAwake(true)
        precondition(prompt.screenAwake && live == 2, "The switch must be on before the relay is parked")
        helper.holds = []
        helper.holdGate = gate
        let releasing = Task { await prompt.setScreenAwake(false) }
        for _ in 0..<200 where helper.holds.count < 1 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(helper.holds.count == 1, "The helper never received the off-relay")
        precondition(live == 0 && !prompt.screenAwake,
                     "Turning the switch off waited for the helper before releasing the screen: \(live) assertion(s) still held")
        precondition(prompt.screenChanging,
                     "The switch must keep reporting itself in flight until the helper answers")
        gate.signal()
        await releasing.value
        helper.holdGate = nil
        precondition(helper.displayHold == false && !prompt.screenAwake && live == 0)
        print("PASS: turning the switch off releases the screen without waiting for the helper")

        helper.behavior = .lateReply
        helper.replyDelay = 5.2
        let defaultClient = PrivilegedHelperClient {
            NSXPCConnection(listenerEndpoint: listener.endpoint)
        }
        let slowSuccess = try await defaultClient.enable()
        precondition(slowSuccess, "A valid slow power operation must outlive the old five-second XPC deadline")
        helper.behavior = .success
        print("PASS: default XPC deadline accepts a successful response after five seconds")

        let restricted = NSXPCListener.anonymous()
        restricted.setConnectionCodeSigningRequirement("identifier \"com.local.KeepAwakeMac.unauthorized-test-client\"")
        restricted.delegate = helper
        restricted.resume()
        let rejectedClient = PrivilegedHelperClient(timeout: 1) {
            NSXPCConnection(listenerEndpoint: restricted.endpoint)
        }
        await expectError("unavailable") { try await rejectedClient.enable() }
        restricted.invalidate()
        print("PASS: the XPC signature boundary rejects a mismatched client")

        let app = AppState(helper: missing, prepareHelper: {}, powerSnapshot: { (100, true) })
        let settings = UserDefaults.standard.dictionaryRepresentation()
        let keys = ["triggerMode", "timerHours", "processName", "batteryFloor", "thermalAutoStop"]
        defer {
            for key in keys {
                if let value = settings[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        app.triggerMode = .manual
        app.batteryFloorPercent = 5
        app.thermalAutoStopEnabled = false
        for _ in 0..<2 {
            await app.toggle()
            guard case .failed(let message) = app.status else {
                fatalError("UI did not leave Working: \(app.status)")
            }
            precondition(message.contains("unavailable"))
        }
        await app.deactivate(reason: "Regression check")
        guard case .failed = app.status else { fatalError("Disable did not report failure") }
        await app.reconcileOnLaunch()
        guard case .failed = app.status else { fatalError("State query hid a transport error") }
        print("PASS: UI exits Working, exposes the error, and permits retry")

        // OUT-4: screen-awake must work with no helper at all. The relay fails,
        // so it is only reported — never fatal, and never an error on the switch.
        var soloAssertions = 0
        let solo = AppState(helper: missing, prepareHelper: {},
                            display: DisplayAwake(create: { _ in soloAssertions += 1; return 1 },
                                                  release: { _ in soloAssertions -= 1 }),
                            powerSnapshot: { (100, true) })
        solo.triggerMode = .manual
        solo.batteryFloorPercent = 5
        solo.thermalAutoStopEnabled = false
        await solo.setScreenAwake(true)
        precondition(solo.screenAwake && solo.screenError == nil && soloAssertions == 2,
                     "Screen-awake must not depend on the helper (OUT-4)")
        precondition(solo.screenWarning == nil, "No lid session runs, so a lost hold is not a user-visible problem")
        await solo.setScreenAwake(false)
        precondition(!solo.screenAwake && soloAssertions == 0)
        print("PASS: screen-awake works with no helper, and the lost hold stays silent")

        // The same relay failing while a lid session is running is user-visible:
        // a closed lid may still blank a screen the user asked to keep on.
        helper.rejectDisplayHold = true
        var warnedAssertions = 0
        let warned = AppState(helper: client, prepareHelper: {},
                              display: DisplayAwake(create: { _ in warnedAssertions += 1; return 1 },
                                                    release: { _ in warnedAssertions -= 1 }),
                              powerSnapshot: { (100, true) })
        warned.triggerMode = .manual
        warned.batteryFloorPercent = 5
        warned.thermalAutoStopEnabled = false
        await warned.setScreenAwake(true)
        precondition(warned.screenAwake && warned.screenWarning == nil,
                     "With no lid session a lost hold has no consequence to report")
        await warned.activate()
        precondition(warned.status == .active && warned.screenWarning != nil,
                     "Under a lid session a lost hold must be surfaced, not swallowed")
        precondition(warned.screenError == nil, "A lost hold is a warning, not a failed switch")
        // The banner describes a hold the helper did not take. Every transition
        // that ends that condition has to clear it — while the relay is still
        // failing, which was the only situation the old code ever cleared it in.
        await warned.setScreenAwake(false)
        precondition(warned.screenWarning == nil && warnedAssertions == 0,
                     "Turning the switch off must clear a warning about that switch")
        precondition(warned.status == .active)
        await warned.toggle()
        precondition(warned.status == .idle && warned.screenWarning == nil,
                     "Turning lid mode off must clear the warning with the lid session it described")
        helper.rejectDisplayHold = false
        await warned.setScreenAwake(true)
        await warned.activate()
        helper.rejectDisplayHold = true
        await warned.setScreenAwake(true)
        precondition(warned.screenWarning != nil, "A rejected relay must warn while a lid session runs")
        await warned.deactivate(reason: "Battery at 4%")
        precondition(warned.screenWarning == nil,
                     "An automatic stop must clear the warning with the lid session it described")
        helper.rejectDisplayHold = false
        precondition(warned.screenWarning == nil && warnedAssertions == 0)
        print("PASS: a lost hold is surfaced only while the lid rule can actually blank, and never outlives it")

        // An automatic stop landing while a turn-on is parked at the registration
        // refresh. It has already said `hold = false`; resuming behind it would
        // leave the helper suppressing a blank the app no longer wants, and both
        // relays succeeded, so nothing would be reported.
        helper.holds = []; helper.displayHold = nil
        var racingAssertions = 0
        let racing = AppState(helper: client,
                              prepareHelper: { try await Task.sleep(nanoseconds: 400_000_000) },
                              display: DisplayAwake(create: { _ in racingAssertions += 1; return 1 },
                                                    release: { _ in racingAssertions -= 1 }),
                              powerSnapshot: { (100, true) })
        racing.triggerMode = .manual; racing.batteryFloorPercent = 5; racing.thermalAutoStopEnabled = false
        let turningOn = Task { await racing.setScreenAwake(true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await racing.deactivate(reason: "Battery at 4%")
        await turningOn.value
        precondition(!racing.screenAwake && racingAssertions == 0)
        precondition(helper.holds == [false] && helper.displayHold == false,
                     "A parked turn-on must not resume behind an automatic stop's release: \(helper.holds)")
        precondition(racing.screenWarning == nil, "Both relays landed, so there is nothing to report — only nothing to leave behind")
        print("PASS: an automatic stop wins against a turn-on parked on the helper")

        // The heartbeat is the other half of what keeps a kept-awake screen from
        // blanking: the helper can restart and come back with no hold in memory
        // while the app still believes it sent one. Delete the heartbeat's
        // re-assert and no other check notices — the app's own state is
        // unchanged and every assertion still holds. The loss has to happen
        // behind the app's back, which is exactly what a restart is.
        helper.reportsEnabled = true
        helper.holds = []; helper.displayHold = nil
        var beatAssertions = 0
        let beat = AppState(helper: client, prepareHelper: {},
                            display: DisplayAwake(create: { _ in beatAssertions += 1; return 1 },
                                                  release: { _ in beatAssertions -= 1 }),
                            powerSnapshot: { (100, true) })
        beat.triggerMode = .manual; beat.batteryFloorPercent = 5; beat.thermalAutoStopEnabled = false
        await beat.activate()
        await beat.setScreenAwake(true)
        precondition(beat.status == .active && beat.screenAwake && helper.displayHold == true,
                     "The session must be up with the hold taken before the helper is interrupted")
        helper.holds = []; helper.displayHold = nil
        var renewed = false
        for _ in 0..<80 where !renewed {
            try await Task.sleep(nanoseconds: 250_000_000)
            renewed = helper.holds.last == true
        }
        precondition(beat.status == .active && beat.screenAwake && beatAssertions > 0,
                     "The heartbeat tore the session down instead of renewing it")
        precondition(renewed && helper.displayHold == true,
                     "A helper that lost the hold in memory never got it back: \(helper.holds)")
        helper.reportsEnabled = false
        await beat.deactivate(reason: "End of the heartbeat check")
        print("PASS: the heartbeat hands a restarted helper the hold it lost")

        try await FeatureCheck.run(client: client, displayHold: { helper.displayHold },
                                   simulateHelperRestart: { helper.displayHold = nil })
        try await checkSwitchOrderings()
    }

    /// The three real orderings, lid closed throughout, driven through the real
    /// AppState, a real XPC connection, and the real `KeepAwakeController` with
    /// only `pmset` faked. The helper's lease timer runs on its own schedule, so
    /// every ordering gets every chance to blank the screen the user is asking
    /// to keep — which is the whole regression: the fix used to work only if
    /// 屏幕常亮 was flipped first.
    @MainActor
    static func checkSwitchOrderings() async throws {
        for ordering in ["屏幕常亮 → 合盖保活", "合盖保活 → 屏幕常亮", "合盖保活 长开 → 屏幕常亮"] {
            let power = ControllerHelper()
            let listener = NSXPCListener.anonymous()
            listener.delegate = power
            listener.resume()
            let client = PrivilegedHelperClient(timeout: 2) {
                NSXPCConnection(listenerEndpoint: listener.endpoint)
            }
            var held = 0
            let app = AppState(helper: client, prepareHelper: {},
                               display: DisplayAwake(create: { _ in held += 1; return 1 },
                                                     release: { _ in held -= 1 }),
                               powerSnapshot: { (100, true) })
            app.triggerMode = .manual; app.batteryFloorPercent = 5; app.thermalAutoStopEnabled = false

            if ordering.hasPrefix("屏幕常亮") { await app.setScreenAwake(true) }
            await app.activate()
            precondition(app.status == .active, "\(ordering): the lid session did not start")
            if ordering.hasPrefix("合盖保活 长开") {
                // The steady state: lid mode has been running long enough for the
                // helper to have made up its mind about a switch that was off.
                await power.ticks(8)
                precondition(power.displaySleeps == 1,
                             "\(ordering): the lid rule should have blanked once while the switch was off")
                await app.setScreenAwake(true)
            } else if !ordering.hasPrefix("屏幕常亮") {
                // The user is still mid-menu when the first ticks land.
                await power.ticks(2)
                await app.setScreenAwake(true)
            }
            await power.ticks(8)
            precondition(app.screenAwake && held == 2, "\(ordering): the switch did not stay on")
            let expected = ordering.hasPrefix("合盖保活 长开") ? 1 : 0
            precondition(power.displaySleeps == expected,
                         "\(ordering): helper blanked the display \(power.displaySleeps) time(s), want \(expected)")
            print("PASS: \(ordering) — lid closed, \(power.displaySleeps) blank(s), screen-awake on")
            await app.deactivate(reason: "End of ordering check")
            listener.invalidate()
            power.cleanUp()
        }
    }
}
