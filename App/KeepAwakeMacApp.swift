import SwiftUI
import ServiceManagement
import IOKit.pwr_mgt

@main
struct KeepAwakeMacApp: App {

    @StateObject private var state = AppState.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.anyAwake ? "moon.zzz.fill" : "moon")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--check-agent-status") {
            Task {
                do {
                    for agent in AgentTask.Agent.allCases {
                        let tasks = try await Task.detached { try AgentTask.discover(agent) }.value
                        print("PASS: \(agent.rawValue): \(tasks.count) running local task(s)")
                    }
                    exit(0)
                } catch { fputs("CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-screen-awake") {
            let display = DisplayAwake()
            func ownedAssertions() -> [[String: Any]] {
                var info: Unmanaged<CFDictionary>?
                guard IOPMCopyAssertionsByProcess(&info) == kIOReturnSuccess,
                      let entries = info?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
                return entries[NSNumber(value: getpid())] ?? []
            }
            do {
                try display.start()
                let types = ownedAssertions().compactMap { $0[kIOPMAssertionTypeKey] as? String }
                guard types.contains(kIOPMAssertionTypePreventUserIdleSystemSleep),
                      !display.isDisplayHeld || types.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep) else {
                    throw HelperService.ServiceError("System did not confirm the screen-awake assertions")
                }
                display.stop()
                guard ownedAssertions().isEmpty else { throw HelperService.ServiceError("Assertions were not released") }
                print("PASS: native screen/system assertions created, confirmed, and released")
                exit(0)
            } catch {
                display.stop(); fputs("CHECK FAILED: \(error.localizedDescription)\n", stderr); exit(1)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--reload-helper") {
            Task { @MainActor in
                do {
                    if HelperService.service.status != .notRegistered {
                        try await HelperService.service.unregister()
                    }
                    try HelperService.prepare()
                    print("PASS: installed helper registered again")
                    exit(0)
                } catch {
                    fputs("RELOAD FAILED: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--check-keep-awake") ||
            ProcessInfo.processInfo.arguments.contains("--check-crash-cleanup") {
            Task { @MainActor in
                do {
                    try HelperService.prepare()
                    let helper = PrivilegedHelperClient.shared
                    guard try await helper.enable(), try await helper.isCurrentlyEnabled() else {
                        throw HelperService.ServiceError("Enable/readback failed")
                    }
                    print("PASS: privileged XPC enabled keep-awake and confirmed readback")
                    fflush(stdout)
                    if ProcessInfo.processInfo.arguments.contains("--check-crash-cleanup") { _exit(0) }
                    guard try await helper.disable(), try await !helper.isCurrentlyEnabled() else {
                        throw HelperService.ServiceError("Disable/readback failed")
                    }
                    print("PASS: privileged XPC restored sleep and confirmed readback")
                    exit(0)
                } catch {
                    _ = try? await PrivilegedHelperClient.shared.disable()
                    fputs("CHECK FAILED: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
            return
        }
        #endif
        if HelperService.service.status == .enabled {
            Task { await AppState.shared.reconcileOnLaunch() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard HelperService.service.status == .enabled else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.deactivate(reason: "App quit")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
