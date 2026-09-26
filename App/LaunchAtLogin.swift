import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.MainApp` so the menu bar UI can toggle
/// "launch at login" without binding to Obj-C API quirks.
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private let service = SMAppService.mainApp

    var isEnabled: Bool {
        service.status == .enabled
    }

    /// Returns true on success. On a non-admin-managed Mac the user may see
    /// a one-time "KeepAwakeMac wants to run in the background" prompt —
    /// that's the system, not us.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }
}