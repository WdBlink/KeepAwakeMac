import Foundation
import IOKit.ps

final class Watchdog {
    private let batteryFloor: Int
    private let thermalAutoStop: Bool
    private let chargingOnly: Bool
    private let powerSnapshot: () -> (percent: Int, onAC: Bool)?
    private let onTrip: (String) -> Void
    private let onBatterySample: (Int) -> Void
    private let onThermalSample: (ProcessInfo.ThermalState) -> Void
    private var timer: Timer?
    private var ioSource: CFRunLoopSource?

    init(batteryFloor: Int, thermalAutoStop: Bool, chargingOnly: Bool = false,
         powerSnapshot: @escaping () -> (percent: Int, onAC: Bool)? = Watchdog.powerSnapshot,
         onTrip: @escaping (String) -> Void,
         onBatterySample: @escaping (Int) -> Void,
         onThermalSample: @escaping (ProcessInfo.ThermalState) -> Void) {
        self.batteryFloor = batteryFloor
        self.thermalAutoStop = thermalAutoStop
        self.chargingOnly = chargingOnly
        self.powerSnapshot = powerSnapshot
        self.onTrip = onTrip
        self.onBatterySample = onBatterySample
        self.onThermalSample = onThermalSample
    }

    func start() {
        stop()
        let context = Unmanaged.passUnretained(self).toOpaque()
        ioSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<Watchdog>.fromOpaque(context).takeUnretainedValue().sample()
        }, context)?.takeRetainedValue()
        if let source = ioSource { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        // This also covers unavailable or missed IOKit notifications.
        timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer!, forMode: .common)
        sample()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let source = ioSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        ioSource = nil
    }

    func stopReason() -> String? {
        let power = powerSnapshot()
        let thermal = ProcessInfo.processInfo.thermalState
        if let percent = power?.percent { onBatterySample(percent) }
        onThermalSample(thermal)
        return Self.stopReason(percent: power?.percent, onAC: power?.onAC, thermal: thermal,
                               batteryFloor: batteryFloor, thermalAutoStop: thermalAutoStop,
                               chargingOnly: chargingOnly)
    }

    private func sample() { if let reason = stopReason() { onTrip(reason) } }

    static func stopReason(percent: Int?, onAC: Bool?, thermal: ProcessInfo.ThermalState,
                           batteryFloor: Int, thermalAutoStop: Bool, chargingOnly: Bool) -> String? {
        guard let percent = percent, let onAC = onAC else { return "Battery status is unavailable" }
        if percent <= batteryFloor { return "Battery at \(percent)% (floor \(batteryFloor)%)" }
        if chargingOnly && !onAC { return "Power adapter disconnected" }
        if thermalAutoStop && thermal == .critical { return "Thermal state: critical" }
        return nil
    }

    static func powerSnapshot() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            return (Int(Double(current) / Double(maximum) * 100), state == kIOPSACPowerValue)
        }
        return nil
    }
}
