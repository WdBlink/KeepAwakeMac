import Foundation

/// UserDefaults-backed settings. Stored in the standard suite so they roam
/// across reinstalls of the same bundle ID.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    var triggerMode: AppState.TriggerMode {
        get { AppState.TriggerMode(rawValue: defaults.string(forKey: "triggerMode") ?? "Manual")
              ?? .manual }
        set { defaults.set(newValue.rawValue, forKey: "triggerMode") }
    }

    var timerHours: Int {
        get { min(24, max(1, defaults.integer(forKey: "timerHours").nonZero(4))) }
        set { defaults.set(newValue, forKey: "timerHours") }
    }

    var processName: String {
        get { defaults.string(forKey: "processName") ?? "Claude" }
        set { defaults.set(newValue, forKey: "processName") }
    }

    var batteryFloorPercent: Int {
        get { min(80, max(5, defaults.integer(forKey: "batteryFloor").nonZero(20))) }
        set { defaults.set(newValue, forKey: "batteryFloor") }
    }

    var thermalAutoStop: Bool {
        get { defaults.object(forKey: "thermalAutoStop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "thermalAutoStop") }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }
}

private extension Int {
    /// Returns the value if non-zero, otherwise `fallback`. Used so a fresh
    /// install doesn't show "0 hours" / "0% battery floor" as default state.
    func nonZero(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
