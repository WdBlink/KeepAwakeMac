import AppKit
import SwiftUI

/// Offscreen layout checks; no desktop capture, helper calls, or real assertions.
@main
struct MenuPreview {
    struct Image {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        subscript(x: Int, y: Int) -> Int { y * width + x }

    }

    /// RGBA8 pixels in one fixed layout, so two renders can be compared. Both
    /// sides go through the same PNG decode: SwiftUI hands back no text and
    /// builds no accessibility tree for a view nobody is reading —
    /// `NSHostingView.accessibilityChildren()` is empty here no matter how long
    /// the run loop spins — so "is this string on screen" is answered by the
    /// pixels, which are the only thing a reader actually gets.
    static func pixels(_ data: Data, fill: NSColor? = nil) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            if let fill {
                context.setFillColor(fill.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Image(bytes: bytes, width: width, height: height) : nil
    }

    /// What two renders of the same menu say when the only difference is one
    /// inserted block: the rows above it are untouched, everything below it is
    /// the old menu moved down by exactly that many points, and the inserted
    /// block itself carries ink. A deleted render branch, a repaint, or a
    /// layout that moved something other than the banner all fail here.
    static func insertedBlock(_ full: Image, _ without: Image) -> (top: Int, height: Int, inked: Int) {
        /// Row `ay` of the first render against row `by` of the second. The two
        /// row numbers are separate because the images are different heights.
        func same(_ a: Image, _ b: Image, _ x: Int, _ ay: Int, _ by: Int) -> Bool {
            let i = a[x, ay] * 4, j = b[x, by] * 4
            return a.bytes[i] == b.bytes[j] && a.bytes[i + 1] == b.bytes[j + 1]
                && a.bytes[i + 2] == b.bytes[j + 2] && a.bytes[i + 3] == b.bytes[j + 3]
        }
        precondition(full.width == without.width,
                     "The banner changed the menu's width, not its height: \(full.width) vs \(without.width)")
        let added = full.height - without.height
        // The menu is 360 points wide; cached bitmaps can be 1x or Retina 2x.
        let scale = Double(full.width) / 360
        precondition(Double(added) >= 20 * scale && Double(added) <= 60 * scale,
                     "The warning banner did not reach the screen as one compact block: it added \(Double(added) / scale) points")
        var top = 0
        while top < without.height && (0..<full.width).allSatisfy({ same(full, without, $0, top, top) }) { top += 1 }
        precondition(top < without.height,
                     "Nothing was inserted: every row of the two menus is identical")
        for y in 0..<top { for x in 0..<full.width {
            precondition(same(full, without, x, y, y),
                         "The banner repainted the menu above it at \(x),\(y)")
        }}
        // Everything after the inserted block is the old menu, moved down.
        for y in top..<without.height where y + added < full.height {
            for x in 0..<full.width {
                precondition(same(full, without, x, y + added, y),
                             "The banner moved the rest of the menu by something other than \(added) points at \(x),\(y)")
            }
        }
        let backdrop = without[0, max(0, top - 1)] * 4
        var inked = 0
        for y in top..<(top + added) where y < full.height { for x in 0..<full.width {
            let i = full[x, y] * 4
            if full.bytes[i] != full.bytes[backdrop] || full.bytes[i + 1] != full.bytes[backdrop + 1]
                || full.bytes[i + 2] != full.bytes[backdrop + 2] { inked += 1 }
        }}
        precondition(inked >= 120, "The \(added) points the banner added are blank")
        return (top, added, inked)
    }

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
        // Screen-awake relays its state to the helper; point it at a service that
        // does not exist so the preview stays offline.
        let offlineHelper = PrivilegedHelperClient(timeout: 0.1) {
            NSXPCConnection(machServiceName: "com.local.KeepAwakeMac.preview.\(UUID().uuidString)",
                            options: .privileged)
        }
        for name in ["idle", "permission", "timer", "agent-empty", "agent-ready", "working", "error", "active", "warning", "login-error", "dark", "overflow"] {
            let appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)!
            application.appearance = appearance
            let state = AppState(helper: offlineHelper, prepareHelper: { throw HelperService.ApprovalRequired() },
                                 display: DisplayAwake(create: { _ in 1 }, release: { _ in }),
                                 agentHome: home, powerSnapshot: { (100, true) },
                                 loginIsEnabled: { false }, setLoginEnabled: { _ in false })
            state.triggerMode = .manual; state.batteryFloorPercent = 20; state.thermalAutoStopEnabled = true
            state.timerHours = 4
            switch name {
            case "login-error":
                state.setLaunchAtLogin(true)
                precondition(state.loginError != nil && !state.launchAtLogin)
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
            case "warning":
                // The real path, not a hand-written banner: a lid session is up
                // and the offline helper cannot be told to stand down, so the
                // hold the switch asked for never reached the thing that decides.
                state.thermalAutoStopEnabled = false
                state.status = .active
                await state.setScreenAwake(true)
                precondition(state.screenWarning != nil,
                             "A lid session whose hold never reached the helper must warn")
            case "overflow":
                state.triggerMode = .agentTask
                state.screenError = "Test display error"
                state.stopMessage = String(repeating: "Task status unavailable. ", count: 60)
            default: break
            }
            let view = MenuContentView().environmentObject(state)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
                .environment(\.controlActiveState, .key)
            // The opaque backdrop goes on before the first layout: swapping the
            // root view afterwards leaves the hosting view drawing nothing.
            let host = NSHostingView(rootView: view.background(Color(NSColor.windowBackgroundColor)))
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
            // PNGs cannot capture the system's behind-window material, so the
            // whole menu renders on a neutral backdrop.
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            // A SwiftUI hosting view is layer-backed; cacheDisplay on it can come
            // back empty, and its layer renders everything.
            if let layer = host.layer {
                NSGraphicsContext.saveGraphicsState()
                if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                    context.saveGraphicsState()
                    let flipped = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
                    NSGraphicsContext.current = flipped
                    layer.render(in: context.cgContext)
                    flipped.restoreGraphicsState()
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                host.cacheDisplay(in: host.bounds, to: bitmap)
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: destination.appendingPathComponent("\(name).png"))
            precondition(pixels(png) != nil, "The rendered menu could not be read back")
            print("PASS: \(name) menu rendered at \(Int(size.width)) × \(Int(size.height))")
            window.contentView = nil
            if state.screenAwake {
                state.status = .idle
                await state.setScreenAwake(false)
            }
        }

        // The warning banner has to be on screen, not merely defined: delete the
        // render branch and every other check in this suite still passes. The
        // `warning` and `active` states differ in exactly one thing — whether
        // the helper could be told to stand down — so the pixels that separate
        // them are the banner.
        //
        // What this deliberately does not claim: that the glyphs it drew were
        // read back and recognised. Offscreen, SwiftUI paints this banner a dim
        // grey that peaks about three times over the backdrop, far too little
        // contrast to identify glyphs by, and a threshold that "recognised" the
        // title here would be tuned to this harness rather than to the words.
        // Which string the banner carries is proved by FeatureCheck's scan of
        // the shipped sources; that a banner is drawn at all is proved here.
        let render = destination.appendingPathComponent("warning.render.txt")
        func image(_ name: String) throws -> Image {
            let url = destination.appendingPathComponent("\(name).png")
            guard let data = try? Data(contentsOf: url), let image = pixels(data) else {
                preconditionFailure("No readable render of the \(name) menu")
            }
            return image
        }
        let warned = try image("warning"), plain = try image("active")
        let block = insertedBlock(warned, plain)
        let points = block.height * 360 / warned.width
        let report = "warning banner on screen: \(points) points inserted at row \(block.top), \(block.inked) pixels of it drawn, the rows above untouched and the rows below moved down by exactly \(points)\n"
        try report.write(to: render, atomically: true, encoding: .utf8)
        print("PASS: " + report.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
