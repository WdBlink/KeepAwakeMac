import Foundation
import Security

/// launchd runs this executable as root after SMAppService approval.
@main
enum KAMHelperMain {
    static func main() throws {
        guard geteuid() == 0 else { throw KeepAwakeController.Failure("The helper must run as root.") }
        let delegate = KAMHelperDelegate()
        try delegate.queue.sync { try delegate.controller.recover() }
        let listener = NSXPCListener(machServiceName: AppConstants.helperMachServiceName)
        // Verify every peer against the containing app's actual code signature.
        // This also pins local ad-hoc builds to their code hash, not just a bundle ID.
        listener.setConnectionCodeSigningRequirement(try appRequirement())
        listener.delegate = delegate
        listener.resume()
        let leaseTimer = DispatchSource.makeTimerSource(queue: delegate.queue)
        leaseTimer.schedule(deadline: .now() + 1, repeating: 1)
        leaseTimer.setEventHandler {
            do {
                try delegate.controller.expireIfNeeded()
                if try delegate.controller.sleepDisplayIfLidClosed() {
                    NSLog("Lid closed: requested display sleep while keeping the system awake.")
                }
            } catch { NSLog("Power monitor: %@", error.localizedDescription) }
        }
        leaseTimer.resume()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: delegate.queue)
        termination.setEventHandler {
            do { try delegate.controller.disable(); exit(0) }
            catch { NSLog("Could not restore sleep: %@", error.localizedDescription); exit(1) }
        }
        termination.resume()
        withExtendedLifetime((delegate, listener, leaseTimer, termination)) { dispatchMain() }
    }

    private static func appRequirement() throws -> String {
        var url = Bundle.main.bundleURL
        while url.pathExtension != "app" && url.path != "/" { url.deleteLastPathComponent() }
        guard url.pathExtension == "app" else { throw KeepAwakeController.Failure("Containing app not found.") }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code = code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement = requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text = text else { throw KeepAwakeController.Failure("App signature could not be verified.") }
        return text as String
    }
}

final class KAMHelperDelegate: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "com.local.KeepAwakeMac.power", qos: .userInitiated)
    let controller = KeepAwakeController()
    private var processMonitor: DispatchSourceProcess?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: KAMHelperProtocol.self)
        connection.exportedObject = KAMHelperSession(delegate: self, pid: connection.processIdentifier)
        connection.resume()
        return true
    }

    func watchProcess(_ pid: pid_t) {
        processMonitor?.cancel()
        let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        monitor.setEventHandler { [weak self] in
            guard let self = self, self.controller.owner == pid else { return }
            try? self.controller.disable()
        }
        monitor.resume()
        processMonitor = monitor
    }
}

private final class KAMHelperSession: NSObject, KAMHelperProtocol {
    let delegate: KAMHelperDelegate
    let pid: pid_t
    init(delegate: KAMHelperDelegate, pid: pid_t) { self.delegate = delegate; self.pid = pid }

    func enableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void) {
        delegate.queue.async { [self] in
            do {
                guard kill(pid, 0) == 0 else { throw KeepAwakeController.Failure("The requesting app has exited.") }
                guard delegate.controller.owner == nil || delegate.controller.owner == pid else {
                    throw KeepAwakeController.Failure("Another session is already active.")
                }
                delegate.watchProcess(pid)
                try delegate.controller.enable(for: pid)
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func disableLidOpenKeepAwake(reply: @escaping (Bool, String?) -> Void) {
        delegate.queue.async { [self] in
            do { try delegate.controller.disable(for: pid); reply(true, nil) }
            catch { reply(false, error.localizedDescription) }
        }
    }

    func currentState(reply: @escaping (Bool, String?) -> Void) {
        delegate.queue.async { [self] in
            do { reply(try delegate.controller.currentState(for: pid), nil) }
            catch { reply(false, error.localizedDescription) }
        }
    }
}
