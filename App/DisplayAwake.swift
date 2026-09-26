import Foundation
import IOKit.pwr_mgt

/// Owns only this app's assertions. Never changes the user's display timeout.
final class DisplayAwake {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private var timer: Timer?
    private let lidClosed: () -> Bool?
    private let create: (String) throws -> IOPMAssertionID
    private let release: (IOPMAssertionID) -> Void
    private(set) var isEnabled = false
    private(set) var isDisplayHeld = false
    var onChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(lidClosed: @escaping () -> Bool? = DisplayAwake.readLidClosed,
         create: @escaping (String) throws -> IOPMAssertionID = DisplayAwake.createAssertion,
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        self.lidClosed = lidClosed
        self.create = create
        self.release = release
    }

    func start() throws {
        guard !isEnabled else { return }
        do {
            systemID = try create(kIOPMAssertionTypePreventUserIdleSystemSleep)
            isEnabled = true
            try updateLid()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                do { try self.updateLid() }
                catch { self.stop(); self.onError?(error) }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch { stop(); throw error }
    }

    func updateLid() throws {
        // Unknown lid state also releases the display assertion. Closed-lid
        // display sleep always takes priority over the screen-awake switch.
        let shouldHold = isEnabled && lidClosed() == false
        if shouldHold && !isDisplayHeld {
            displayID = try create(kIOPMAssertionTypePreventUserIdleDisplaySleep)
        } else if !shouldHold && isDisplayHeld {
            release(displayID); displayID = 0
        }
        isDisplayHeld = shouldHold
        onChange?(shouldHold)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if isDisplayHeld { release(displayID) }
        if isEnabled { release(systemID) }
        displayID = 0; systemID = 0
        isDisplayHeld = false; isEnabled = false
        onChange?(false)
    }

    deinit { stop() }

    static func readLidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

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
