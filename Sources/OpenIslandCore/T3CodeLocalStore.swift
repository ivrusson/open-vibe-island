import Foundation

/// Snapshot of an active (or recently active) T3 thread for island display.
public struct T3CodeThreadSnapshot: Equatable, Sendable {
    public var threadID: String
    public var title: String
    public var projectTitle: String?
    public var workspacePath: String?
    public var provider: String
    public var runStatus: String
    public var pendingApprovalCount: Int
    public var pendingUserInputCount: Int
    public var updatedAt: Date?

    public var islandSessionID: String {
        T3CodeThreadMapper.islandSessionID(from: threadID)
    }

    public init(
        threadID: String,
        title: String,
        projectTitle: String? = nil,
        workspacePath: String? = nil,
        provider: String,
        runStatus: String,
        pendingApprovalCount: Int = 0,
        pendingUserInputCount: Int = 0,
        updatedAt: Date? = nil
    ) {
        self.threadID = threadID
        self.title = title
        self.projectTitle = projectTitle
        self.workspacePath = workspacePath
        self.provider = provider
        self.runStatus = runStatus
        self.pendingApprovalCount = pendingApprovalCount
        self.pendingUserInputCount = pendingUserInputCount
        self.updatedAt = updatedAt
    }
}

public struct T3CodeServerRuntime: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var origin: String
    public var pid: Int32?
    public var startedAt: String?

    public init(host: String, port: Int, origin: String, pid: Int32? = nil, startedAt: String? = nil) {
        self.host = host
        self.port = port
        self.origin = origin
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// Reads T3 Code's local userdata (server-runtime.json + projection SQLite).
/// Local-first: no remote auth required when Open Island runs on the same machine.
public struct T3CodeLocalStore: Sendable {
    public var userdataDirectory: URL

    public init(
        userdataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata", isDirectory: true)
    ) {
        self.userdataDirectory = userdataDirectory
    }

    public var runtimeURL: URL {
        userdataDirectory.appendingPathComponent("server-runtime.json")
    }

    public var databaseURL: URL {
        // Prefer v2 projection DB when present.
        let v2 = userdataDirectory.appendingPathComponent("statev2.sqlite")
        if FileManager.default.fileExists(atPath: v2.path) {
            return v2
        }
        return userdataDirectory.appendingPathComponent("state.sqlite")
    }

    public func loadRuntime() -> T3CodeServerRuntime? {
        guard let data = try? Data(contentsOf: runtimeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let port = (json["port"] as? Int) ?? Int("\(json["port"] ?? "")") ?? 3773
        let host = (json["host"] as? String) ?? "127.0.0.1"
        let origin = (json["origin"] as? String) ?? "http://127.0.0.1:\(port)"
        let pid = (json["pid"] as? Int).map(Int32.init)
            ?? Int32("\(json["pid"] ?? "")")
        let startedAt = json["startedAt"] as? String
        return T3CodeServerRuntime(host: host, port: port, origin: origin, pid: pid, startedAt: startedAt)
    }

    /// Active runs that should appear on the island (running / waiting / starting / …).
    public func loadActiveThreadSnapshots() throws -> [T3CodeThreadSnapshot] {
        let dbPath = databaseURL.path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        let sql = """
        SELECT
          r.thread_id,
          r.status,
          COALESCE(r.provider_instance_id, r.provider, '') AS provider,
          r.requested_at,
          COALESCE(t.title, r.thread_id) AS title,
          t.payload_json,
          p.title AS project_title,
          p.workspace_root,
          COALESCE(pt.pending_approval_count, 0) AS pending_approval_count,
          COALESCE(pt.pending_user_input_count, 0) AS pending_user_input_count
        FROM orchestration_v2_projection_runs r
        LEFT JOIN orchestration_v2_projection_threads t ON t.thread_id = r.thread_id
        LEFT JOIN projection_projects p ON p.project_id = t.project_id
        LEFT JOIN projection_threads pt ON pt.thread_id = r.thread_id
        WHERE r.completed_at IS NULL
          AND r.status IN ('running','starting','queued','waiting','preparing')
          AND (t.deleted_at IS NULL OR t.deleted_at = '')
        ORDER BY r.requested_at DESC;
        """

        let rows = try Self.queryJSON(databasePath: dbPath, sql: sql)
        var seen = Set<String>()
        var snapshots: [T3CodeThreadSnapshot] = []

        for row in rows {
            guard let threadID = row["thread_id"] as? String, !threadID.isEmpty else { continue }
            if seen.contains(threadID) { continue }
            seen.insert(threadID)

            let payload = Self.decodeJSONObject(row["payload_json"] as? String)
            let worktree = (payload?["worktreePath"] as? String)
                ?? (row["workspace_root"] as? String)
            let status = (row["status"] as? String) ?? "running"
            let provider = (row["provider"] as? String) ?? "unknown"
            let title = (row["title"] as? String) ?? threadID
            let projectTitle = row["project_title"] as? String
            let pendingApproval = intValue(row["pending_approval_count"])
            let pendingInput = intValue(row["pending_user_input_count"])
            let updatedAt = Self.parseISO8601(row["requested_at"] as? String)

            snapshots.append(
                T3CodeThreadSnapshot(
                    threadID: threadID,
                    title: title,
                    projectTitle: projectTitle,
                    workspacePath: worktree,
                    provider: provider,
                    runStatus: status,
                    pendingApprovalCount: pendingApproval,
                    pendingUserInputCount: pendingInput,
                    updatedAt: updatedAt
                )
            )
        }
        return snapshots
    }

    // MARK: - sqlite3 CLI helper (no SQLite.swift dependency)

    public static func queryJSON(databasePath: String, sql: String) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-json", databasePath, sql]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "sqlite error"
            throw T3CodeLocalStoreError.queryFailed(message)
        }
        if data.isEmpty { return [] }
        let root = try JSONSerialization.jsonObject(with: data)
        return (root as? [[String: Any]]) ?? []
    }

    private static func decodeJSONObject(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseISO8601(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String, let number = Int(text) { return number }
        return 0
    }
}

public enum T3CodeLocalStoreError: Error, Equatable {
    case queryFailed(String)
}
