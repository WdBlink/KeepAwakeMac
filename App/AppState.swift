import Foundation
import Combine
import IOKit.ps

/// The two switches share stop conditions, but own separate power requests.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle, activating, active, deactivating, failed(String)
        var isOn: Bool { self == .active }
        var canStart: Bool {
            switch self { case .idle, .failed: return true; default: return false }
        }
    }
    enum TriggerMode: String, CaseIterable, Identifiable {
        case manual = "Manual", timer = "Timer", agentTask = "Agent Task Finished"
        case process = "While Process", chargingOnly = "Charging Only"
        var id: String { rawValue }
    }

    @Published var status: Status = .idle
    @Published var needsHelperApproval = false
    @Published private(set) var screenAwake = false
    @Published private(set) var screenChanging = false
    @Published var screenError: String?
    /// Set when the helper could not be told to stand down, so the closed lid may
    /// still blank a screen the user asked to keep on.
    @Published var screenWarning: String?
    @Published var stopMessage: String?
    @Published var agent: AgentTask.Agent = .codex
    @Published var selectedTaskID = ""
    @Published private(set) var agentTasks: [AgentTask] = []
    @Published private(set) var loadingTasks = false
    @Published private(set) var taskError: String?
    @Published var triggerMode: TriggerMode { didSet { Settings.shared.triggerMode = triggerMode } }
    @Published var timerHours: Int { didSet { Settings.shared.timerHours = timerHours } }
    @Published var processName: String { didSet { Settings.shared.processName = processName } }
    @Published var batteryFloorPercent: Int { didSet { Settings.shared.batteryFloorPercent = batteryFloorPercent } }
    @Published var thermalAutoStopEnabled: Bool { didSet { Settings.shared.thermalAutoStop = thermalAutoStopEnabled } }
    @Published var launchAtLogin: Bool {
        didSet {
            Settings.shared.launchAtLogin = launchAtLogin
            LaunchAtLoginService.shared.setEnabled(launchAtLogin)
        }
    }
    @Published var batteryPercent = 100
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    var anyAwake: Bool { status.isOn || screenAwake }
    var isBusy: Bool { status == .activating || status == .deactivating || screenChanging }
    var canEditSettings: Bool { !anyAwake && !isBusy }

    private let helper: PrivilegedHelperClient
    private let display: DisplayAwake
    private let prepareHelper: () async throws -> Void
    private let agentHome: URL
    private let powerSnapshot: () -> (percent: Int, onAC: Bool)?
    private var watchdog: Watchdog?
    private var processScope: ProcessScope?
    private var timerTask: Task<Void, Never>?
    private var agentWatchTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var generation = 0

    init(helper: PrivilegedHelperClient = .shared,
         prepareHelper: @escaping () async throws -> Void = HelperService.prepare,
         display: DisplayAwake = DisplayAwake(),
         agentHome: URL = FileManager.default.homeDirectoryForCurrentUser,
         powerSnapshot: @escaping () -> (percent: Int, onAC: Bool)? = Watchdog.powerSnapshot) {
        self.helper = helper; self.prepareHelper = prepareHelper; self.display = display
        self.agentHome = agentHome
        self.powerSnapshot = powerSnapshot
        let s = Settings.shared
        triggerMode = s.triggerMode; timerHours = s.timerHours; processName = s.processName
        batteryFloorPercent = s.batteryFloorPercent; thermalAutoStopEnabled = s.thermalAutoStop
        launchAtLogin = s.launchAtLogin
    }

    func refreshAgentTasks() async {
        let selectedAgent = agent
        let home = agentHome
        loadingTasks = true; taskError = nil
        do {
            let tasks = try await Task.detached(priority: .userInitiated) { try AgentTask.discover(selectedAgent, home: home) }.value
            guard agent == selectedAgent else { return }
            agentTasks = tasks
            if !tasks.contains(where: { $0.id == selectedTaskID }) { selectedTaskID = tasks.first?.id ?? "" }
        } catch {
            guard agent == selectedAgent else { return }
            agentTasks = []; selectedTaskID = ""; taskError = error.localizedDescription
        }
        if agent == selectedAgent { loadingTasks = false }
    }

    func reconcileOnLaunch() async {
        guard status == .idle else { return }
        status = .deactivating
        do {
            try await prepareHelper()
            if try await helper.isCurrentlyEnabled(), try await !helper.disable() {
                throw HelperService.ServiceError("Could not reset keep-awake on launch")
            }
            status = .idle
        } catch {
            needsHelperApproval = error is HelperService.ApprovalRequired
            status = .failed(error.localizedDescription)
        }
    }

    func toggle() async {
        guard !isBusy else { return }
        if status.isOn { await turnOffLid(reason: "User toggled off") }
        else if status.canStart { await activate() }
    }

    func activate() async {
        guard status.canStart && !screenChanging else { return }
        status = .activating; needsHelperApproval = false; stopMessage = nil
        let operation = generation
        do {
            try await prepareHelper()
            guard operation == generation, status == .activating else { return }
            try await startSessionMonitoring()
            guard operation == generation, status == .activating else { return }
            guard try await helper.enable() else { throw HelperService.ServiceError("The helper could not enable keep-awake.") }
            guard operation == generation, status == .activating else {
                _ = try? await helper.disable()
                return
            }
            status = .active
            // A new session must learn the current screen-awake state: the helper
            // keeps the hold across session transitions, and re-sending covers a
            // helper that restarted and lost it.
            await tellHelperDisplayHold(screenAwake)
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self, self.status == .active else { return }
                    do {
                        if try await !self.helper.isCurrentlyEnabled() {
                            await self.turnOffLid(reason: "Lid-close keep-awake ended")
                            return
                        }
                        // Re-assert the hold so a restarted helper cannot leave the
                        // screen blanking under a screen-awake session.
                        await self.tellHelperDisplayHold(self.screenAwake)
                    } catch {
                        await self.turnOffLid(reason: "Lost connection to the keep-awake service")
                        return
                    }
                }
            }
        } catch {
            guard operation == generation, status == .activating else { return }
            if !screenAwake { stopSessionMonitoring() }
            needsHelperApproval = error is HelperService.ApprovalRequired
            status = .failed(error.localizedDescription)
        }
    }

    func setScreenAwake(_ enabled: Bool) async {
        guard !isBusy else { return }
        screenError = nil
        // The disable path is busy too: each XPC call owns its own connection, so
        // two overlapping relays would race and the last reply — not the last
        // click — would decide what the helper believes.
        screenChanging = true
        defer { screenChanging = false }
        let operation = generation
        if !enabled {
            await tellHelperDisplayHold(false)
            // A newer transition already told the helper what it believes.
            guard operation == generation else { return }
            display.stop(); screenAwake = false
            if !status.isOn { stopSessionMonitoring() }
            return
        }
        stopMessage = nil
        do {
            try await startSessionMonitoring()
            guard operation == generation else { return }
            try display.start()
            screenAwake = true
            // Tell the helper only after the assertion exists: a slow or missing
            // helper must never delay the switch taking effect on its own. An
            // in-place update can leave an older daemon running that does not
            // know this call, so refresh the registration first.
            try? await prepareHelper()
            await tellHelperDisplayHold(true)
        } catch {
            screenError = error.localizedDescription
            if !status.isOn { stopSessionMonitoring() }
        }
    }

    /// All automatic stop rules (and Quit) stop both switches together.
    func deactivate(reason: String) async {
        generation += 1
        stopMessage = reason
        display.stop(); screenAwake = false
        await tellHelperDisplayHold(false)
        stopSessionMonitoring()
        if status != .idle { await turnOffLid(reason: reason) }
    }

    /// Keeps the helper's lid-close display sleep in step with this switch. The
    /// hold only suppresses that blank, and screen-awake works without a helper
    /// at all, so a failure here must not fail the switch. It is reported rather
    /// than dropped: while a lid session runs, a lost hold means the closed lid
    /// blanks a screen the user asked to keep on — their original symptom, with
    /// no explanation otherwise. Never throws, so it cannot trip the heartbeat.
    private func tellHelperDisplayHold(_ held: Bool) async {
        do {
            guard try await helper.setDisplayHold(held) else {
                setScreenWarning(held ? "后台服务未确认屏幕常亮请求，合盖后仍可能熄屏。" : nil)
                return
            }
            setScreenWarning(nil)
        } catch {
            guard held, status.isOn else {
                // With no lid session the helper never blanks the display, so a
                // missing or unapproved service is expected and only logged.
                NSLog("KeepAwakeMac: screen-awake hold not delivered: %@", error.localizedDescription)
                return
            }
            setScreenWarning("后台服务未接受屏幕常亮请求（\(error.localizedDescription)），合盖后仍可能熄屏。")
        }
    }

    /// The heartbeat re-sends the hold every few seconds; skip the no-op writes so
    /// an unchanged warning does not republish the menu on every tick.
    private func setScreenWarning(_ message: String?) {
        if screenWarning != message { screenWarning = message }
    }

    private func turnOffLid(reason: String) async {
        guard status != .deactivating else { return }
        status = .deactivating
        heartbeatTask?.cancel(); heartbeatTask = nil
        do {
            status = try await helper.disable() ? .idle : .failed("Could not turn off (\(reason))")
        } catch { status = .failed("Could not turn off: \(error.localizedDescription)") }
        if !screenAwake { stopSessionMonitoring() }
    }

    private func startSessionMonitoring() async throws {
        guard watchdog == nil else { return } // A second switch does not reset the timer/task.
        guard (5...80).contains(batteryFloorPercent), (1...24).contains(timerHours) else {
            throw HelperService.ServiceError("Check the battery limit and timer settings.")
        }
        if triggerMode == .process && !ProcessScope.isRunning(processName) {
            throw HelperService.ServiceError("Start the selected app before enabling keep-awake.")
        }
        var watchedTask: AgentTask?
        let operation = generation
        if triggerMode == .agentTask {
            guard let task = agentTasks.first(where: { $0.id == selectedTaskID && $0.agent == agent }) else {
                throw HelperService.ServiceError("Refresh and select a running Agent task first.")
            }
            guard try await Task.detached(priority: .userInitiated, operation: { try task.phase() }).value == .running else {
                throw HelperService.ServiceError("That task is no longer running. Refresh the task list.")
            }
            watchedTask = task
        }
        guard operation == generation else { throw CancellationError() }
        let monitor = Watchdog(batteryFloor: batteryFloorPercent, thermalAutoStop: thermalAutoStopEnabled,
                               chargingOnly: triggerMode == .chargingOnly,
                               powerSnapshot: powerSnapshot,
                               onTrip: { [weak self] reason in
            Task { @MainActor in
                guard self?.generation == operation else { return }
                await self?.deactivate(reason: reason)
            }
        }, onBatterySample: { [weak self] in self?.batteryPercent = $0 },
           onThermalSample: { [weak self] in self?.thermalState = $0 })
        if let reason = monitor.stopReason() { throw HelperService.ServiceError(reason) }
        watchdog = monitor; monitor.start()
        if triggerMode == .process {
            let scope = ProcessScope(processName: processName) { [weak self] in
                Task { @MainActor in
                    guard self?.generation == operation else { return }
                    await self?.deactivate(reason: "Selected app exited")
                }
            }
            processScope = scope; scope.start()
        }
        if triggerMode == .timer {
            timerTask = Task { [weak self, timerHours] in
                do { try await Task.sleep(nanoseconds: UInt64(timerHours) * 3600 * 1_000_000_000) } catch { return }
                await self?.deactivate(reason: "Timer elapsed")
            }
        }
        if let task = watchedTask {
            agentWatchTask = Task { [weak self] in
                var completedSamples = 0
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        let phase = try await Task.detached(priority: .utility) { try task.phase() }.value
                        guard !Task.isCancelled else { return }
                        switch phase {
                        case .running: completedSamples = 0
                        case .completed:
                            completedSamples += 1
                            // Two explicit idle snapshots avoid stopping between a
                            // completed turn and an immediately queued follow-up.
                            if completedSamples >= 2 {
                                await self?.deactivate(reason: "\(task.agent.rawValue) task finished")
                                return
                            }
                        case .stopped:
                            await self?.deactivate(reason: "Agent task stopped or failed")
                            return
                        case .unknown:
                            throw HelperService.ServiceError("Agent task status is unavailable; keep-awake stopped.")
                        }
                    } catch is CancellationError { return }
                    catch {
                        guard !Task.isCancelled else { return }
                        await self?.deactivate(reason: "Cannot monitor Agent task: \(error.localizedDescription)")
                        return
                    }
                }
            }
        }
    }

    private func stopSessionMonitoring() {
        generation += 1
        watchdog?.stop(); watchdog = nil
        processScope?.stop(); processScope = nil
        timerTask?.cancel(); timerTask = nil
        agentWatchTask?.cancel(); agentWatchTask = nil
    }
}
