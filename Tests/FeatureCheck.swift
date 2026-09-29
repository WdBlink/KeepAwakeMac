import Foundation
import IOKit.pwr_mgt
import SQLite3

enum FeatureCheck {
    static func expect(_ value: @autoclosure () throws -> Bool) rethrows {
        let result = try value()
        precondition(result)
    }
    @MainActor
    static func run(client: PrivilegedHelperClient, displayHold: () -> Bool?,
                    simulateHelperRestart: () -> Void) async throws {
        // OUT-6: the retired rule must not reappear in any shipped string.
        for phrase in MenuCopy.retired {
            precondition(!MenuCopy.all.contains { $0.contains(phrase) },
                         "Retired copy \"\(phrase)\" is back in the menu")
        }
        precondition(MenuCopy.precedence.contains("屏幕常亮优先") && MenuCopy.precedenceHelp.contains("不再请求合盖熄屏"),
                     "The menu must state the switch outranks the closed-lid blank")
        print("PASS: menu copy states the precedence and no longer promises the closed-lid rule")

        // The display assertion no longer depends on the lid at all: take it once
        // and account for every id created and released.
        var assertions: [IOPMAssertionID: String] = [:]
        var nextID: IOPMAssertionID = 0
        var releases = 0
        var failDisplay = false
        let display = DisplayAwake(create: { type in
            if failDisplay && type == kIOPMAssertionTypePreventUserIdleDisplaySleep {
                throw HelperService.ServiceError("Test display failure")
            }
            nextID += 1; assertions[nextID] = type; return nextID
        }, release: { id in releases += 1; assertions.removeValue(forKey: id) })
        try display.start()
        precondition(assertions.count == 2 && display.isEnabled && releases == 0,
                     "The switch must take both the system and the display assertion")
        try display.start()
        precondition(assertions.count == 2 && releases == 0, "Starting twice must not re-assert")
        display.stop(); display.stop()
        precondition(assertions.isEmpty && releases == 2 && !display.isEnabled,
                     "stop must release every held assertion exactly once")
        failDisplay = true
        do { try display.start(); fatalError("Expected assertion creation failure") }
        catch { precondition(assertions.isEmpty && !display.isEnabled, "A failed start must roll back") }
        failDisplay = false
        print("PASS: both assertions taken once, released once, and rolled back on failure")

        let denied = AppState(helper: client, prepareHelper: { throw HelperService.ApprovalRequired() },
                              display: display, powerSnapshot: { (100, true) })
        denied.triggerMode = .manual; denied.batteryFloorPercent = 5; denied.thermalAutoStopEnabled = false
        await denied.setScreenAwake(true)
        precondition(denied.screenAwake && denied.status == .idle)
        precondition(displayHold() == true, "The helper must be told to stop blanking a kept-awake screen")
        await denied.activate()
        precondition(denied.needsHelperApproval && denied.screenAwake, "Lid permission failure must not stop screen mode")
        await denied.setScreenAwake(false)
        precondition(assertions.isEmpty && displayHold() == false,
                     "Turning the switch off must hand the lid rule back to the helper")

        let app = AppState(helper: client, prepareHelper: {}, display: display, powerSnapshot: { (100, true) })
        app.triggerMode = .manual; app.batteryFloorPercent = 5; app.thermalAutoStopEnabled = false
        await app.setScreenAwake(true)
        await app.activate()
        precondition(app.status == .active && app.screenAwake && !app.canEditSettings)
        precondition(displayHold() == true, "Both switches on must keep the helper from blanking")
        // The regression the reviews found: a lid-mode cycle must not leave the
        // helper believing the closed lid may blank a screen the user keeps on.
        await app.toggle()
        precondition(app.status == .idle && app.screenAwake && displayHold() == true,
                     "Switching lid mode off must preserve screen mode and its hold")
        await app.activate()
        precondition(displayHold() == true, "A new lid session must re-assert the screen-awake hold")
        // A restarted helper comes back with no hold in memory. Re-sending on
        // every new session is what closes that window; nothing else would.
        simulateHelperRestart()
        precondition(displayHold() == nil)
        await app.toggle()
        await app.activate()
        precondition(displayHold() == true, "A new lid session must re-assert a hold a restarted helper lost")
        await app.setScreenAwake(false)
        precondition(app.status == .active && !app.screenAwake && assertions.isEmpty && displayHold() == false)
        await app.setScreenAwake(true)
        await app.deactivate(reason: "Battery/thermal/timer stop")
        precondition(app.status == .idle && !app.screenAwake && assertions.isEmpty && app.canEditSettings)
        precondition(displayHold() == false, "An automatic stop must also release the helper's display hold")
        print("PASS: independent switches, hold across lid-mode cycles, helper approval gaps, shared automatic stop")

        let start: [String: Any] = ["type": "event_msg", "payload": ["type": "task_started"]]
        let finish: [String: Any] = ["type": "event_msg", "payload": ["type": "task_complete"]]
        let tool: [String: Any] = ["type": "response_item", "payload": ["type": "function_call"]]
        precondition(AgentTask.phase([start, tool], agent: .codex) == .running)
        precondition(AgentTask.phase([start, tool, finish], agent: .codex) == .completed)
        precondition(AgentTask.phase([finish, start], agent: .codex) == .running)
        precondition(AgentTask.phase([["type": "unknown"]], agent: .codex) == .unknown)
        let duration: [String: Any] = ["type": "system", "subtype": "turn_duration"]
        let pending: [String: Any] = ["type": "system", "subtype": "turn_duration", "pendingBackgroundAgentCount": 1]
        let workflow: [String: Any] = ["type": "system", "subtype": "turn_duration", "pendingWorkflowCount": 1]
        let assistant: [String: Any] = ["type": "assistant", "message": ["stop_reason": "tool_use"]]
        precondition(AgentTask.phase([assistant], agent: .claude) == .running)
        precondition(AgentTask.phase([assistant, pending], agent: .claude) == .running)
        precondition(AgentTask.phase([assistant, workflow], agent: .claude) == .running)
        precondition(AgentTask.phase([assistant, duration], agent: .claude) == .completed)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("check.jsonl")
        func write(_ rows: [[String: Any]]) throws {
            var data = Data()
            for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
            try data.write(to: file, options: .atomic)
        }
        try write([start, tool])
        let tasks = try AgentTask.discover(.codex, home: home)
        try expect(tasks.count == 1 && (try tasks[0].phase()) == .running)
        let watcher = AppState(helper: client, prepareHelper: {}, display: display,
                               agentHome: home, powerSnapshot: { (100, true) })
        watcher.triggerMode = .agentTask; watcher.batteryFloorPercent = 5; watcher.thermalAutoStopEnabled = false
        await watcher.refreshAgentTasks()
        await watcher.setScreenAwake(true); await watcher.activate()
        precondition(watcher.anyAwake && watcher.screenAwake)
        try write([start, tool, finish])
        try await Task.sleep(nanoseconds: 4_700_000_000)
        precondition(!watcher.anyAwake && watcher.status == .idle && assertions.isEmpty)
        precondition(watcher.stopMessage == "Codex task finished")
        try expect(AgentTask.discover(.codex, home: home).isEmpty)

        // In-progress writes and corrupt records must never look like completion.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"type\":".utf8)); try handle.close()
        try expect(tasks[0].phase() == .running)
        try Data("{bad json}\n".utf8).write(to: file)
        do { _ = try tasks[0].phase(); fatalError("Corrupt task records must report failure") } catch {}

        let dbURL = home.appendingPathComponent(".minimax/v2/sqlite/runtime-state.sqlite")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        precondition(sqlite3_open(dbURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK) }
        sql("CREATE TABLE local_runtime_sessions(session_id TEXT, title TEXT, workspace_dir TEXT, status TEXT, archived INTEGER, visibility TEXT, updated_at_ms INTEGER)")
        sql("INSERT INTO local_runtime_sessions VALUES('task-1','Test',NULL,'started',0,'visible',1)")
        let miniTasks = try AgentTask.discover(.mcode, home: home)
        precondition(miniTasks.count == 1)
        sql("UPDATE local_runtime_sessions SET status='idle'")
        try expect(miniTasks[0].phase() == .completed)
        sql("UPDATE local_runtime_sessions SET status='interrupted'")
        try expect(miniTasks[0].phase() == .stopped)
        sql("UPDATE local_runtime_sessions SET status='future_status'")
        try expect(miniTasks[0].phase() == .unknown)
        print("PASS: Codex/Claude/mcode task completion, background work, malformed records, and automatic stop of both modes")
    }
}
