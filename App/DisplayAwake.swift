import Foundation
import IOKit.pwr_mgt

/// Owns only this app's assertions. Never changes the user's display timeout.
final class DisplayAwake {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private let create: (String) throws -> IOPMAssertionID
    private let release: (IOPMAssertionID) -> Void
    /// Both assertions are taken together, so this is the whole state.
    private(set) var isEnabled = false

    init(create: @escaping (String) throws -> IOPMAssertionID = DisplayAwake.createAssertion,
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.create = create
        self.release = release
    }

    func start() throws {
        guard !isEnabled else { return }
        do {
            systemID = try create(kIOPMAssertionTypePreventUserIdleSystemSleep)
            isEnabled = true
            // The explicit screen-awake switch outranks closed-lid display sleep,
            // so the display assertion is held for as long as the switch is on.
            // The helper separately stops issuing `pmset displaysleepnow`, which
            // no assertion can override. Nothing here observes the lid, so there
            // is no polling timer and no mid-session creation that could fail:
            // a creation error surfaces as this method's throw.
            displayID = try create(kIOPMAssertionTypePreventUserIdleDisplaySleep)
        } catch { stop(); throw error }
    }

    func stop() {
        if systemID != 0 { release(systemID) }
        if displayID != 0 { release(displayID) }
        displayID = 0; systemID = 0
        isEnabled = false
    }

    deinit { stop() }

    private static func createAssertion(_ type: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "KeepAwakeMac — screen awake" as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw HelperService.ServiceError("Could not keep the screen awake (\(result)).")
        }
        return id
    }
}
