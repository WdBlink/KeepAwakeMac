import Foundation
import ServiceManagement
import Security

@MainActor
enum HelperService {
    static let service = SMAppService.daemon(plistName: "com.local.KeepAwakeMac.Helper.plist")

    static func prepare() async throws {
        try await prepare(registrationID: appIdentity(), defaults: .standard,
                          status: { service.status }, register: { try service.register() },
                          unregister: { try await service.unregister() },
                          runningProtocol: runningHelperProtocol)
    }

    /// The contract version the daemon that is actually running implements, or
    /// nil when nothing answers this app's contract — either because no daemon
    /// is up yet, or because the one that is up predates the call. Both mean the
    /// registration cannot be trusted: the stored identity describes a bundle,
    /// and launchd keeps running whatever binary it last launched from it.
    private static func runningHelperProtocol() async -> Int? {
        let client = PrivilegedHelperClient(timeout: 2)
        return try? await client.protocolVersion()
    }

    // SMAppService.status describes approval, not whether launchd can still
    // resolve this build. Ad-hoc updates change the containing app's signature,
    // and a daemon launched from an older bundle keeps running under KeepAlive —
    // so the running contract version is a second, independent staleness signal.
    static func prepare(registrationID: String, defaults: UserDefaults,
                        status: () -> SMAppService.Status,
                        register: () throws -> Void,
                        unregister: () async throws -> Void,
                        runningProtocol: () async -> Int? = { AppConstants.helperProtocolVersion }
    ) async throws {
        let key = "helperRegistrationIdentity"
        // An unapproved service cannot answer; leave its pending registration intact.
        let stale: Bool
        if status() == .enabled {
            stale = await runningProtocol() != AppConstants.helperProtocolVersion
        } else {
            stale = false
        }
        let changed = defaults.string(forKey: key) != registrationID || stale
        if changed && status() != .notRegistered && status() != .notFound {
            try await unregister()
        }
        if changed || status() == .notRegistered || status() == .notFound {
            do {
                try register()
                defaults.set(registrationID, forKey: key)
            }
            catch {
                let failure = error as NSError
                if status() == .requiresApproval {
                    // Approval can finish later. Do not unregister again on retry.
                    defaults.set(registrationID, forKey: key)
                }
                if status() == .requiresApproval ||
                    (failure.domain == "SMAppServiceErrorDomain" && failure.code == 1) {
                    throw ApprovalRequired()
                }
                throw error
            }
        }
        switch status() {
        case .enabled: return
        case .requiresApproval:
            throw ApprovalRequired()
        default:
            throw ServiceError("The keep-awake service could not be registered. Run the installed app from Applications.")
        }
    }

    private static func appIdentity() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let info = info as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data else {
            throw ServiceError("The app signature could not be read. Reinstall KeepAwakeMac in Applications.")
        }
        return Bundle.main.bundleURL.path + ":" + hash.base64EncodedString()
    }

    struct ApprovalRequired: LocalizedError {
        var errorDescription: String? {
            "Allow KeepAwakeMac in System Settings → General → Login Items & Extensions, then try again."
        }
    }

    struct ServiceError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
