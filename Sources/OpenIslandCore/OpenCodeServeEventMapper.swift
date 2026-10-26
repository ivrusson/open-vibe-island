import Foundation

/// Maps OpenCode server SSE / session JSON into Open Island `AgentEvent`s.
public enum OpenCodeServeEventMapper {
    public static let sessionIDPrefix = "opencode-"

    public static func islandSessionID(from openCodeSessionID: String) -> String {
        if openCodeSessionID.hasPrefix(sessionIDPrefix) {
            return openCodeSessionID
        }
        return sessionIDPrefix + openCodeSessionID
    }

    public static func openCodeSessionID(from islandSessionID: String) -> String {
        if islandSessionID.hasPrefix(sessionIDPrefix) {
            return String(islandSessionID.dropFirst(sessionIDPrefix.count))
        }
        return islandSessionID
    }

    /// Map a raw SSE JSON object (`type` + `properties`/`data`) to zero or more events.
    public static func mapSSEEvent(
        type: String,
        properties: [String: Any],
        hostTerminalApp: String = "OpenChamber",
        now: Date = .now
    ) -> [AgentEvent] {
        switch type {
        case "session.created":
            return mapSessionCreated(properties, hostTerminalApp: hostTerminalApp, now: now)

        case "session.deleted":
            if let sid = sessionID(in: properties) {
                return [
                    .sessionCompleted(
                        SessionCompleted(
                            sessionID: islandSessionID(from: sid),
                            summary: "OpenCode session ended.",
                            timestamp: now,
                            isSessionEnd: true
                        )
                    ),
                ]
            }

        case "session.next.prompt.admitted", "session.prompt.admitted":
            return mapPromptAdmitted(properties, now: now)

        case "session.execution.started":
            if let sid = sessionID(in: properties) {
                return [
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: islandSessionID(from: sid),
                            summary: "OpenCode is working…",
                            phase: .running,
                            timestamp: now
                        )
                    ),
                ]
            }

        case "session.execution.succeeded",
             "session.execution.failed",
             "session.execution.interrupted":
            if let sid = sessionID(in: properties) {
                let summary: String
                switch type {
                case "session.execution.failed": summary = "OpenCode turn failed."
                case "session.execution.interrupted": summary = "OpenCode turn interrupted."
                default: summary = "OpenCode turn completed."
                }
                return [
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: islandSessionID(from: sid),
                            summary: summary,
                            phase: .completed,
                            timestamp: now
                        )
                    ),
                ]
            }

        case "session.status":
            return mapSessionStatus(properties, now: now)

        case "session.tool.called", "session.tool.input.started":
            if let sid = sessionID(in: properties) {
                let tool = stringValue(properties["name"])
                    ?? stringValue(properties["tool"])
                    ?? "Tool"
                return [
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: islandSessionID(from: sid),
                            summary: "OpenCode is using \(tool)…",
                            phase: .running,
                            timestamp: now
                        )
                    ),
                    .openCodeSessionMetadataUpdated(
                        OpenCodeSessionMetadataUpdated(
                            sessionID: islandSessionID(from: sid),
                            openCodeMetadata: OpenCodeSessionMetadata(currentTool: tool),
                            timestamp: now
                        )
                    ),
                ]
            }

        case "session.tool.success", "session.tool.error", "session.tool.failed":
            if let sid = sessionID(in: properties) {
                return [
                    .activityUpdated(
                        SessionActivityUpdated(
                            sessionID: islandSessionID(from: sid),
                            summary: "OpenCode finished a tool.",
                            phase: .running,
                            timestamp: now
                        )
                    ),
                ]
            }

        case "permission.asked", "permission.v2.asked":
            return mapPermission(properties, now: now)

        case "form.created":
            return mapForm(properties, now: now)

        default:
            break
        }
        return []
    }

    /// Default freshness window for list-sync without an explicit `busy` status.
    public static let sessionListFreshness: TimeInterval = 30 * 60

    /// Whether a `GET /api/session` row should create an island card.
    ///
    /// OpenCode returns the full session history. Only import sessions that are
    /// actively working (`busy`/`running`) or still in-flight with a recent
    /// update and no idle/outcome markers. Historical idle sessions stay out.
    public static func shouldImportFromSessionList(
        _ item: [String: Any],
        now: Date = .now,
        maxAge: TimeInterval = sessionListFreshness
    ) -> Bool {
        let statusType = ((item["status"] as? [String: Any]).flatMap { stringValue($0["type"]) })
            ?? stringValue(item["status"])
        if statusType == "busy" || statusType == "running" {
            return true
        }
        if statusType == "idle" {
            return false
        }
        if item["outcome"] != nil {
            return false
        }
        let time = item["time"] as? [String: Any]
        if time?["idle"] != nil {
            return false
        }
        guard let updatedMs = millisecondTimestamp(time?["updated"]) else {
            return false
        }
        let updated = Date(timeIntervalSince1970: updatedMs / 1000)
        return now.timeIntervalSince(updated) <= maxAge
    }

    /// Map a session list item from `GET /api/session`.
    /// Returns `nil` for historical / idle rows so sync cannot flood the island.
    public static func mapSessionListItem(
        _ item: [String: Any],
        hostTerminalApp: String = "OpenChamber",
        now: Date = .now,
        maxAge: TimeInterval = sessionListFreshness
    ) -> AgentEvent? {
        guard shouldImportFromSessionList(item, now: now, maxAge: maxAge) else { return nil }
        guard let rawID = sessionID(in: item) else { return nil }
        let directory = directory(in: item) ?? NSHomeDirectory()
        let workspace = URL(fileURLWithPath: directory).lastPathComponent
        let title = stringValue(item["slug"])
            ?? stringValue(item["title"])
            ?? "OpenCode · \(workspace)"

        return .sessionStarted(
            SessionStarted(
                sessionID: islandSessionID(from: rawID),
                title: title,
                tool: .openCode,
                origin: .live,
                initialPhase: .running,
                summary: "OpenCode session in \(workspace).",
                timestamp: now,
                jumpTarget: JumpTarget(
                    terminalApp: hostTerminalApp,
                    workspaceName: workspace,
                    paneTitle: title,
                    workingDirectory: directory
                ),
                openCodeMetadata: OpenCodeSessionMetadata()
            )
        )
    }

    // MARK: - Private mappers

    private static func mapSessionCreated(
        _ properties: [String: Any],
        hostTerminalApp: String,
        now: Date
    ) -> [AgentEvent] {
        let info = (properties["info"] as? [String: Any]) ?? properties
        guard let rawID = sessionID(in: info) ?? sessionID(in: properties) else { return [] }
        let directory = directory(in: info) ?? directory(in: properties) ?? NSHomeDirectory()
        let workspace = URL(fileURLWithPath: directory).lastPathComponent
        let slug = stringValue(info["slug"])
        let title = slug.map { "OpenCode · \($0)" } ?? "OpenCode · \(workspace)"

        return [
            .sessionStarted(
                SessionStarted(
                    sessionID: islandSessionID(from: rawID),
                    title: title,
                    tool: .openCode,
                    origin: .live,
                    initialPhase: .running,
                    summary: "Started OpenCode session in \(workspace).",
                    timestamp: now,
                    jumpTarget: JumpTarget(
                        terminalApp: hostTerminalApp,
                        workspaceName: workspace,
                        paneTitle: title,
                        workingDirectory: directory
                    ),
                    openCodeMetadata: OpenCodeSessionMetadata()
                )
            ),
        ]
    }

    private static func mapPromptAdmitted(_ properties: [String: Any], now: Date) -> [AgentEvent] {
        guard let sid = sessionID(in: properties) else { return [] }
        let text = promptText(properties["prompt"])
            ?? promptText(properties["text"])
            ?? promptText(properties["content"])
            ?? "OpenCode received a prompt."
        let islandID = islandSessionID(from: sid)
        return [
            .activityUpdated(
                SessionActivityUpdated(
                    sessionID: islandID,
                    summary: "Prompt: \(String(text.prefix(80)))",
                    phase: .running,
                    timestamp: now
                )
            ),
            .openCodeSessionMetadataUpdated(
                OpenCodeSessionMetadataUpdated(
                    sessionID: islandID,
                    openCodeMetadata: OpenCodeSessionMetadata(
                        initialUserPrompt: text,
                        lastUserPrompt: text
                    ),
                    timestamp: now
                )
            ),
        ]
    }

    private static func mapSessionStatus(_ properties: [String: Any], now: Date) -> [AgentEvent] {
        guard let sid = sessionID(in: properties) else { return [] }
        let islandID = islandSessionID(from: sid)
        if properties["error"] != nil {
            return [
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: islandID,
                        summary: "OpenCode turn failed.",
                        phase: .completed,
                        timestamp: now
                    )
                ),
            ]
        }
        let status = properties["status"] as? [String: Any]
        let statusType = stringValue(status?["type"])
        if statusType == "busy" || statusType == "running" {
            return [
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: islandID,
                        summary: "OpenCode is working…",
                        phase: .running,
                        timestamp: now
                    )
                ),
            ]
        }
        if statusType == "idle" {
            return [
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: islandID,
                        summary: "OpenCode is idle.",
                        phase: .completed,
                        timestamp: now
                    )
                ),
            ]
        }
        return []
    }

    private static func mapPermission(_ properties: [String: Any], now: Date) -> [AgentEvent] {
        guard let sid = sessionID(in: properties) else { return [] }
        let permission = stringValue(properties["permission"])
            ?? stringValue(properties["action"])
            ?? "tool"
        let patterns = (properties["patterns"] as? [Any]) ?? (properties["resources"] as? [Any]) ?? []
        let first = patterns.compactMap { stringValue($0) }.first ?? ""
        return [
            .permissionRequested(
                PermissionRequested(
                    sessionID: islandSessionID(from: sid),
                    request: PermissionRequest(
                        title: "Allow \(permission)",
                        summary: first.isEmpty
                            ? "OpenCode wants to run \(permission)."
                            : "OpenCode wants to run \(permission): \(first)",
                        affectedPath: first,
                        toolName: permission
                    ),
                    timestamp: now
                )
            ),
        ]
    }

    private static func mapForm(_ properties: [String: Any], now: Date) -> [AgentEvent] {
        let form = (properties["form"] as? [String: Any]) ?? properties
        guard let sid = sessionID(in: form) ?? sessionID(in: properties) else { return [] }
        let title = stringValue(form["title"]) ?? "OpenCode has a question"
        return [
            .questionAsked(
                QuestionAsked(
                    sessionID: islandSessionID(from: sid),
                    prompt: QuestionPrompt(
                        title: title,
                        options: []
                    ),
                    timestamp: now
                )
            ),
        ]
    }

    // MARK: - JSON helpers

    public static func promptText(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String, !text.isEmpty { return text }
            if let text = object["content"] as? String, !text.isEmpty { return text }
            if let nested = object["prompt"] {
                return promptText(nested)
            }
        }
        return nil
    }

    private static func sessionID(in object: [String: Any]) -> String? {
        stringValue(object["sessionID"])
            ?? stringValue(object["sessionId"])
            ?? stringValue(object["id"])
    }

    private static func directory(in object: [String: Any]) -> String? {
        if let location = object["location"] as? [String: Any],
           let directory = stringValue(location["directory"]) {
            return directory
        }
        return stringValue(object["directory"]) ?? stringValue(object["cwd"])
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func millisecondTimestamp(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let number = Double(text) { return number }
        return nil
    }
}
