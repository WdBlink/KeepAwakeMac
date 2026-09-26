import Foundation
import IOKit.pwr_mgt
import SQLite3

enum FeatureCheck {
    static func expect(_ value: @autoclosure () throws -> Bool) rethrows {
        let result = try value()
        precondition(result)
    }
    @MainActor
    static func run(client: PrivilegedHelperClient) async throws {
        var closed: Bool? = false
        var assertions: [IOPMAssertionID: String] = [:]
        var nextID: IOPMAssertionID = 0
        var failDisplay = false
        let display = DisplayAwake(lidClosed: { closed }, create: { type in
            if failDisplay && type == kIOPMAssertionTypePreventUserIdleDisplaySleep {
                throw HelperService.ServiceError("Test display failure")
            }
            nextID += 1; assertions[nextID] = type; return nextID
        }, release: { assertions.removeValue(forKey: $0) })
        try display.start()
        precondition(assertions.count == 2 && display.isDisplayHeld)
        closed = true; try display.updateLid()
        precondition(assertions.count == 1 && !display.isDisplayHeld)
        closed = false; try display.updateLid()
        precondition(assertions.count == 2 && display.isDisplayHeld)
        closed = nil; try display.updateLid()
        precondition(assertions.count == 1 && !display.isDisplayHeld)
        display.stop(); display.stop()
        precondition(assertions.isEmpty)
        closed = false; failDisplay = true
        do { try display.start(); fatalError("Expected assertion creation failure") }
        catch { precondition(assertions.isEmpty && !display.isEnabled) }
        failDisplay = false
        print("PASS: screen/system assertions, closed/unknown lid priority, reopen, and failure cleanup")

        let denied = AppState(helper: client, prepareHelper: { throw HelperService.ApprovalRequired() },
                              display: display, powerSnapshot: { (100, true) })
        denied.triggerMode = .manual; denied.batteryFloorPercent = 5; denied.thermalAutoStopEnabled = false
        await denied.setScreenAwake(true)
        precondition(denied.screenAwake && denied.status == .idle)
        await denied.activate()
        precondition(denied.needsHelperApproval && denied.screenAwake, "Lid permission failure must not stop screen mode")
        await denied.setScreenAwake(false)
        precondition(assertions.isEmpty)

        let app = AppState(helper: client, prepareHelper: {}, display: display, powerSnapshot: { (100, true) })
        app.triggerMode = .manual; app.batteryFloorPercent = 5; app.thermalAutoStopEnabled = false
        await app.setScreenAwake(true)
        await app.activate()
        precondition(app.status == .active && app.screenAwake && !app.canEditSettings)
        await app.toggle()
        precondition(app.status == .idle && app.screenAwake, "Switching off lid mode must preserve screen mode")
        await app.activate()
        await app.setScreenAwake(false)
        precondition(app.status == .active && !app.screenAwake && assertions.isEmpty)
        await app.setScreenAwake(true)
        await app.deactivate(reason: "Battery/thermal/timer stop")
        precondition(app.status == .idle && !app.screenAwake && assertions.isEmpty && app.canEditSettings)
        print("PASS: independent switches, screen mode without helper approval, shared automatic stop")

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
