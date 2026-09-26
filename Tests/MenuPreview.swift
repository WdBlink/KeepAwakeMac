import AppKit
import SwiftUI

/// Offscreen layout checks; no desktop capture, helper calls, or real assertions.
@main
struct MenuPreview {
    @MainActor
    static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let defaults = UserDefaults.standard
        let keys = ["triggerMode", "timerHours", "processName", "batteryFloor", "thermalAutoStop"]
        let saved = defaults.dictionaryRepresentation()
        defer {
            for key in keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for name in ["idle", "permission", "timer", "agent-empty", "agent-ready", "working", "error", "active", "dark", "overflow"] {
            let appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)!
            application.appearance = appearance
            let state = AppState(prepareHelper: { throw HelperService.ApprovalRequired() },
                                 display: DisplayAwake(lidClosed: { false }, create: { _ in 1 }, release: { _ in }),
                                 agentHome: home, powerSnapshot: { (100, true) })
            state.triggerMode = .manual; state.batteryFloorPercent = 20; state.thermalAutoStopEnabled = true
            state.timerHours = 4
            switch name {
            case "permission", "dark":
                state.status = .failed(HelperService.ApprovalRequired().localizedDescription)
                state.needsHelperApproval = true
            case "timer": state.triggerMode = .timer
            case "agent-empty": state.triggerMode = .agentTask
            case "agent-ready":
                state.triggerMode = .agentTask
                let folder = home.appendingPathComponent(".codex/sessions")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let records = "{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/projects/KeepAwakeMac\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
                try Data(records.utf8).write(to: folder.appendingPathComponent("preview-keepawake.jsonl"))
                await state.refreshAgentTasks()
            case "working": state.status = .activating
            case "error": state.status = .failed("macOS power settings did not respond in time.")
            case "active":
                state.thermalAutoStopEnabled = false
                await state.setScreenAwake(true)
                precondition(state.screenAwake)
                state.status = .active
            case "overflow":
                state.triggerMode = .agentTask
                state.screenError = "Test display error"
                state.stopMessage = String(repeating: "Task status unavailable. ", count: 60)
            default: break
            }
            let view = MenuContentView().environmentObject(state)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .environment(\.controlActiveState, .key)
            let host = NSHostingView(rootView: view.background(Color.clear))
            host.appearance = appearance
            _ = host.fittingSize
            // Let the view's async discovery finish before capturing empty/ready states.
            try await Task.sleep(nanoseconds: 100_000_000)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = appearance
            window.contentView = host
            try await Task.sleep(nanoseconds: 100_000_000)
            for _ in 0..<20 where state.loadingTasks {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            precondition(!state.loadingTasks, "Task discovery did not settle")
            if name == "agent-empty" { precondition(state.agentTasks.isEmpty) }
            if name == "agent-ready" { precondition(state.agentTasks.count == 1) }
            let size = host.fittingSize
            let proposedSize = NSHostingController(rootView: view).sizeThatFits(in: NSSize(width: 360, height: 720))
            // Reproduce the real menu window's tall proposal. A flexible maxHeight
            // used to expand every state to 720 points with large empty margins.
            precondition(proposedSize.height <= size.height + 8,
                         "Menu stretched beyond its content: \(name) \(proposedSize)")
            if name == "idle" { precondition(size.height <= 350, "Default menu is no longer compact") }
            if name == "overflow" {
                precondition(size.height == min(720, (NSScreen.main?.visibleFrame.height ?? 900) - 60),
                             "Long content must use the bounded scrolling layout")
            }
            precondition(size.width == 360 && size.height > 300 && size.height <= 720,
                         "Unexpected menu dimensions: \(name) \(size)")
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // PNGs cannot capture the system's behind-window material. Render a
            // neutral backdrop only for readable layout previews.
            host.rootView = view.background(Color(NSColor.windowBackgroundColor))
            host.layoutSubtreeIfNeeded()
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: destination.appendingPathComponent("\(name).png"))
            print("PASS: \(name) menu rendered at \(Int(size.width)) × \(Int(size.height))")
            window.contentView = nil
            if state.screenAwake {
                state.status = .idle
                await state.setScreenAwake(false)
            }
        }
    }
}
