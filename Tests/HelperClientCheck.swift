import Foundation
import ServiceManagement

// Uses an anonymous XPC service; never runs pmset or changes power settings.
private final class TestHelper: NSObject, KAMHelperProtocol, NSXPCListenerDelegate {
    enum Behavior { case success, reject, disconnect, silent, lateReply }
    var behavior: Behavior = .success
    var replyDelay: TimeInterval = 0.4
    var displayHold: Bool?
    var rejectDisplayHold = false

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

    func currentState(reply: @escaping (Bool, String?) -> Void) { reply(false, nil) }

    func setDisplayHold(_ held: Bool, reply: @escaping (Bool, String?) -> Void) {
        guard !rejectDisplayHold else { reply(false, "Test helper rejected the display hold"); return }
        displayHold = held
        reply(true, nil)
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
        try await prepare("build-3")
        precondition(registrations == 3 && removals == 3)
        print("PASS: stale service repair, build changes, failure retry, and pending approval")
    }

    static func expectError(_ fragment: String,
                            _ call: () async throws -> Bool) async {
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
        print("PASS: missing service errors for enable, disable, state query, display hold, and retry")

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
        print("PASS: replies, rejection, disconnect, timeout, late reply, recovery, and the display-hold relay")

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
        helper.rejectDisplayHold = false
        await warned.setScreenAwake(false)
        precondition(warned.screenWarning == nil && warnedAssertions == 0)
        print("PASS: a lost hold is surfaced only while the lid rule can actually blank")
        try await FeatureCheck.run(client: client, displayHold: { helper.displayHold },
                                   simulateHelperRestart: { helper.displayHold = nil })
    }
}
