import Foundation

public enum T3CodeThreadMapper {
    public static let sessionIDPrefix = "t3-"

    public static func islandSessionID(from threadID: String) -> String {
        if threadID.hasPrefix(sessionIDPrefix) { return threadID }
        return sessionIDPrefix + threadID
    }

    public static func threadID(from islandSessionID: String) -> String {
        if islandSessionID.hasPrefix(sessionIDPrefix) {
            return String(islandSessionID.dropFirst(sessionIDPrefix.count))
        }
        return islandSessionID
    }

    public static func agentTool(forProvider provider: String) -> AgentTool {
        let key = provider.lowercased()
        if key.contains("claude") { return .claudeCode }
        if key.contains("codex") { return .codex }
        if key.contains("cursor") { return .cursor }
        if key.contains("opencode") || key.contains("open-code") { return .openCode }
        if key.contains("grok") { return .grokBuild }
        if key.contains("gemini") { return .geminiCLI }
        if key.contains("pi") { return .pi }
        if key.contains("hermes") { return .hermes }
        if key.contains("kimi") { return .kimiCLI }
        // Unknown T3 drivers still surface as Cursor-like cockpit work rather than inventing a tool.
        return .cursor
    }

    public static func mapSnapshot(
        _ snapshot: T3CodeThreadSnapshot,
        previouslyTracked: Bool,
        now: Date = .now
    ) -> [AgentEvent] {
        let sessionID = snapshot.islandSessionID
        let cwd = snapshot.workspacePath
        let workspace = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? snapshot.projectTitle
            ?? "T3"
        let tool = agentTool(forProvider: snapshot.provider)
        let jump = JumpTarget(
            terminalApp: "T3 Code",
            workspaceName: workspace,
            paneTitle: snapshot.title,
            workingDirectory: cwd
        )

        var events: [AgentEvent] = []

        if !previouslyTracked {
            let phase = phase(for: snapshot)
            events.append(
                .sessionStarted(
                    SessionStarted(
                        sessionID: sessionID,
                        title: snapshot.title,
                        tool: tool,
                        origin: .live,
                        initialPhase: phase,
                        summary: summary(for: snapshot),
                        timestamp: now,
                        jumpTarget: jump
                    )
                )
            )
        }

        if snapshot.pendingApprovalCount > 0 || snapshot.runStatus.lowercased() == "waiting" {
            events.append(
                .permissionRequested(
                    PermissionRequested(
                        sessionID: sessionID,
                        request: PermissionRequest(
                            title: "Approval Required",
                            summary: "T3 Code is waiting for approval.",
                            affectedPath: cwd ?? "",
                            requiresTerminalApproval: true
                        ),
                        timestamp: now
                    )
                )
            )
        } else if snapshot.pendingUserInputCount > 0 {
            events.append(
                .questionAsked(
                    QuestionAsked(
                        sessionID: sessionID,
                        prompt: QuestionPrompt(
                            title: "T3 Code is waiting for input.",
                            options: []
                        ),
                        timestamp: now
                    )
                )
            )
        } else {
            events.append(
                .activityUpdated(
                    SessionActivityUpdated(
                        sessionID: sessionID,
                        summary: summary(for: snapshot),
                        phase: phase(for: snapshot),
                        timestamp: now
                    )
                )
            )
        }

        // Keep jump target on OpenChamber-style host activation.
        events.append(
            .jumpTargetUpdated(
                JumpTargetUpdated(
                    sessionID: sessionID,
                    jumpTarget: jump,
                    timestamp: now
                )
            )
        )

        return events
    }

    public static func mapMissingTrackedSession(
        sessionID: String,
        now: Date = .now
    ) -> AgentEvent {
        .activityUpdated(
            SessionActivityUpdated(
                sessionID: sessionID,
                summary: "T3 thread is idle.",
                phase: .completed,
                timestamp: now
            )
        )
    }

    private static func phase(for snapshot: T3CodeThreadSnapshot) -> SessionPhase {
        if snapshot.pendingApprovalCount > 0 || snapshot.runStatus.lowercased() == "waiting" {
            return .waitingForApproval
        }
        if snapshot.pendingUserInputCount > 0 {
            return .waitingForAnswer
        }
        switch snapshot.runStatus.lowercased() {
        case "running", "starting", "queued", "preparing":
            return .running
        default:
            return .completed
        }
    }

    private static func summary(for snapshot: T3CodeThreadSnapshot) -> String {
        switch snapshot.runStatus.lowercased() {
        case "waiting":
            return "T3 Code is waiting…"
        case "queued", "preparing", "starting":
            return "T3 Code is starting…"
        case "running":
            return "T3 Code is working…"
        default:
            return "T3 Code · \(snapshot.title)"
        }
    }
}
