import Foundation
import SQLite3

/// Read-only adapters: explicit local lifecycle records, never CPU/idle guesses.
struct AgentTask: Identifiable, Equatable {
    enum Agent: String, CaseIterable, Identifiable {
        case codex = "Codex", claude = "Claude Code", mcode = "MiniMax Code / mcode"
        var id: String { rawValue }
    }
    enum Phase: Equatable { case running, completed, stopped, unknown }
    let id: String
    let agent: Agent
    let location: URL
    let title: String

    static func discover(_ agent: Agent, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [AgentTask] {
        let fm = FileManager.default
        if agent == .mcode {
            let db = home.appendingPathComponent(".minimax/v2/sqlite/runtime-state.sqlite")
            guard fm.fileExists(atPath: db.path) else { return [] }
            return try query(db, "SELECT session_id, COALESCE(title, workspace_dir, session_id), status FROM local_runtime_sessions WHERE archived = 0 AND visibility = 'visible' ORDER BY updated_at_ms DESC LIMIT 100")
                .filter { mcodePhase($0[2]) == .running }
                .map { AgentTask(id: $0[0], agent: agent, location: db, title: shortTitle($0[1], id: $0[0])) }
        }
        let root = home.appendingPathComponent(agent == .codex ? ".codex/sessions" : ".claude/projects")
        guard fm.fileExists(atPath: root.path) else { return [] }
        var scanError: Error?
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                       options: [.skipsHiddenFiles], errorHandler: { _, error in scanError = error; return false }) else {
            throw HelperService.ServiceError("Could not read \(agent.rawValue) tasks.")
        }
        var candidates: [(URL, Date)] = []
        for case let file as URL in files {
            if file.lastPathComponent == "subagents" { files.skipDescendants(); continue }
            guard file.pathExtension == "jsonl" else { continue }
            let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            candidates.append((file, date))
        }
        if let scanError { throw scanError }
        var codexTitles: [String: String] = [:]
        if agent == .codex {
            // Optional display names only; completion never depends on this index.
            let index = home.appendingPathComponent(".codex/state_5.sqlite")
            if let rows = try? query(index, "SELECT rollout_path, title FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 100") {
                for row in rows { codexTitles[row[0]] = row[1] }
            }
        }
        // ponytail: recent 100 sessions keep discovery bounded; add an indexed
        // session browser only if users need older, still-running sessions.
        return try candidates.sorted { $0.1 > $1.1 }.prefix(100).compactMap { file, _ in
            let records = try tail(file)
            guard phase(records, agent: agent) == .running else { return nil }
            let id = file.deletingPathExtension().lastPathComponent
            let cwd = records.reversed().compactMap { row -> String? in
                if agent == .claude { return row["cwd"] as? String }
                return (row["payload"] as? [String: Any])?["cwd"] as? String
            }.first
            return AgentTask(id: id, agent: agent, location: file,
                             title: shortTitle(codexTitles[file.path] ?? cwd ?? agent.rawValue, id: id))
        }
    }

    func phase() throws -> Phase {
        if agent == .mcode {
            let rows = try Self.query(location, "SELECT status FROM local_runtime_sessions WHERE session_id = ?", parameter: id)
            return rows.first.map { Self.mcodePhase($0[0]) } ?? .unknown
        }
        return Self.phase(try Self.tail(location), agent: agent)
    }

    static func phase(_ records: [[String: Any]], agent: Agent) -> Phase {
        for row in records.reversed() {
            if row["type"] as? String == "pending_write" { return .running }
            if agent == .codex {
                let payload = row["payload"] as? [String: Any] ?? [:]
                if row["type"] as? String == "event_msg" {
                    switch payload["type"] as? String {
                    case "task_complete", "task_completed": return .completed
                    case "turn_aborted": return .stopped
                    case "task_started": return .running
                    default: break
                    }
                }
                if row["type"] as? String == "response_item" { return .running }
            } else if agent == .claude {
                guard row["isSidechain"] as? Bool != true else { continue }
                if row["type"] as? String == "system", row["subtype"] as? String == "turn_duration" {
                    let pending = (row["pendingBackgroundAgentCount"] as? Int ?? 0) + (row["pendingWorkflowCount"] as? Int ?? 0)
                    return pending > 0 ? .running : .completed
                }
                if ["user", "assistant"].contains(row["type"] as? String ?? "") { return .running }
            }
        }
        return .unknown
    }

    static func mcodePhase(_ status: String) -> Phase {
        switch status {
        case "started": return .running
        case "idle": return .completed
        case "aborted", "error", "interrupted": return .stopped
        default: return .unknown
        }
    }

    private static func shortTitle(_ text: String, id: String) -> String {
        let name = text.hasPrefix("/") ? URL(fileURLWithPath: text).lastPathComponent : text
        return "\(name.prefix(48)) · \(id.suffix(8))"
    }

    private static func tail(_ file: URL) throws -> [[String: Any]] {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > 2_097_152 ? size - 2_097_152 : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        // Drop incomplete first/last lines: an in-progress write is not an error
        // or completion. If no lifecycle evidence survives, return unknown.
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        let partialWrite = data.last != 10 && !lines.isEmpty
        if partialWrite { lines.removeLast() }
        var records = try lines.filter { !$0.isEmpty }.map { line -> [String: Any] in
            guard let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw HelperService.ServiceError("Unrecognized Agent task record.")
            }
            return row
        }
        if partialWrite { records.append(["type": "pending_write"]) }
        return records
    }

    private static func query(_ url: URL, _ sql: String, parameter: String? = nil) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw HelperService.ServiceError("Could not read MiniMax Code task status.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw HelperService.ServiceError("This MiniMax Code task format is not supported.")
        }
        defer { sqlite3_finalize(statement) }
        if let parameter {
            sqlite3_bind_text(statement, 1, parameter, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var rows: [[String]] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? ""
            })
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw HelperService.ServiceError("Agent task status is temporarily unavailable.") }
        return rows
    }
}
