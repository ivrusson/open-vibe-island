import Foundation
import OpenIslandCore

/// Connects to OpenChamber's managed `opencode serve` (HTTP + SSE) and emits
/// `AgentEvent`s — same lifecycle pattern as `CodexAppServerCoordinator`.
@Observable
@MainActor
final class OpenChamberOpenCodeCoordinator {
    @ObservationIgnored
    private var client: OpenCodeServeClient?

    @ObservationIgnored
    private var connectTask: Task<Void, Never>?

    @ObservationIgnored
    var onEvent: ((AgentEvent) -> Void)?

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var isSessionTracked: ((String) -> Bool)?

    private(set) var isConnected = false

    func ensureConnected() {
        guard !isConnected, connectTask == nil else { return }

        connectTask = Task { [weak self] in
            guard let self else { return }
            let endpoints = OpenCodeServeDiscovery.discoverOpenChamberEndpoints()
            guard let endpoint = endpoints.first else {
                self.connectTask = nil
                self.onStatusMessage?("OpenChamber OpenCode server not found.")
                return
            }

            let newClient = OpenCodeServeClient(endpoint: endpoint)
            newClient.onEvents = { [weak self] events in
                Task { @MainActor [weak self] in
                    self?.emit(events)
                }
            }
            newClient.onStatus = { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.onStatusMessage?(message)
                }
            }

            self.client = newClient
            self.isConnected = true
            self.connectTask = nil
            self.onStatusMessage?(
                "Connected to OpenChamber OpenCode on \(endpoint.host):\(endpoint.port)."
            )

            await self.syncExistingSessions(using: newClient)
            newClient.startEventStream(hostTerminalApp: "OpenChamber")
        }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        client?.stop()
        client = nil
        isConnected = false
    }

    /// Re-poll session list while connected (called from monitoring ticks).
    func refreshSessionsIfConnected() {
        guard isConnected, let client else { return }
        Task { [weak self] in
            await self?.syncExistingSessions(using: client)
        }
    }

    private func syncExistingSessions(using client: OpenCodeServeClient) async {
        do {
            let events = try await client.syncSessionEvents(hostTerminalApp: "OpenChamber")
            var created = 0
            for event in events {
                if case let .sessionStarted(payload) = event {
                    if isSessionTracked?(payload.sessionID) == true { continue }
                    onEvent?(event)
                    created += 1
                } else if case let .activityUpdated(payload) = event {
                    if isSessionTracked?(payload.sessionID) == true {
                        onEvent?(event)
                    }
                } else {
                    onEvent?(event)
                }
            }
            if created > 0 {
                onStatusMessage?("Synced \(created) OpenChamber OpenCode session(s).")
            }
        } catch {
            onStatusMessage?("OpenChamber session sync failed: \(error.localizedDescription)")
        }
    }

    private func emit(_ events: [AgentEvent]) {
        for event in events {
            if case let .sessionStarted(payload) = event {
                if isSessionTracked?(payload.sessionID) == true { continue }
                onEvent?(event)
                continue
            }

            // Live SSE activity can arrive for a resumed session that never
            // passed the list-sync filter. Seed a minimal card first so
            // activity / permission / question updates are not dropped.
            // Do not seed from completion/delete — that would resurrect history.
            if Self.shouldSeedMissingSession(for: event),
               let sessionID = Self.sessionID(for: event),
               isSessionTracked?(sessionID) != true {
                onEvent?(
                    .sessionStarted(
                        SessionStarted(
                            sessionID: sessionID,
                            title: "OpenCode",
                            tool: .openCode,
                            origin: .live,
                            initialPhase: .running,
                            summary: "OpenCode session via OpenChamber.",
                            timestamp: .now,
                            jumpTarget: JumpTarget(
                                terminalApp: "OpenChamber",
                                workspaceName: "OpenChamber",
                                paneTitle: "OpenCode",
                                workingDirectory: nil
                            ),
                            openCodeMetadata: OpenCodeSessionMetadata()
                        )
                    )
                )
            }
            onEvent?(event)
        }
    }

    private static func shouldSeedMissingSession(for event: AgentEvent) -> Bool {
        switch event {
        case .activityUpdated, .permissionRequested, .questionAsked,
             .openCodeSessionMetadataUpdated, .jumpTargetUpdated:
            return true
        default:
            return false
        }
    }

    private static func sessionID(for event: AgentEvent) -> String? {
        switch event {
        case let .sessionStarted(payload): payload.sessionID
        case let .activityUpdated(payload): payload.sessionID
        case let .permissionRequested(payload): payload.sessionID
        case let .questionAsked(payload): payload.sessionID
        case let .sessionCompleted(payload): payload.sessionID
        case let .jumpTargetUpdated(payload): payload.sessionID
        case let .sessionMetadataUpdated(payload): payload.sessionID
        case let .claudeSessionMetadataUpdated(payload): payload.sessionID
        case let .geminiSessionMetadataUpdated(payload): payload.sessionID
        case let .openCodeSessionMetadataUpdated(payload): payload.sessionID
        case let .cursorSessionMetadataUpdated(payload): payload.sessionID
        case let .piSessionMetadataUpdated(payload): payload.sessionID
        case let .hermesSessionMetadataUpdated(payload): payload.sessionID
        case let .sessionHeartbeat(payload): payload.sessionID
        case let .actionableStateResolved(payload): payload.sessionID
        }
    }
}
