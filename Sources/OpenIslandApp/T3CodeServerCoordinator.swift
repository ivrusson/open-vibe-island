import Foundation
import OpenIslandCore

/// Polls T3 Code's local userdata projection DB for active threads and emits
/// `AgentEvent`s. Server-primary path — no provider hooks required.
@Observable
@MainActor
final class T3CodeServerCoordinator {
    @ObservationIgnored
    private var pollTask: Task<Void, Never>?

    @ObservationIgnored
    private var trackedIslandSessionIDs = Set<String>()

    @ObservationIgnored
    var onEvent: ((AgentEvent) -> Void)?

    @ObservationIgnored
    var onStatusMessage: ((String) -> Void)?

    @ObservationIgnored
    var isSessionTracked: ((String) -> Bool)?

    @ObservationIgnored
    var store: T3CodeLocalStore = T3CodeLocalStore()

    private(set) var isConnected = false

    /// Poll interval while T3 Code is running.
    var pollIntervalNanoseconds: UInt64 = 2_000_000_000

    func ensureConnected() {
        guard !isConnected, pollTask == nil else { return }

        guard store.loadRuntime() != nil || FileManager.default.fileExists(atPath: store.databaseURL.path) else {
            onStatusMessage?("T3 Code local store not found.")
            return
        }

        isConnected = true
        onStatusMessage?("Watching T3 Code local sessions.")
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isConnected {
                self.pollOnce()
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
            }
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        isConnected = false
        trackedIslandSessionIDs.removeAll()
    }

    func pollOnce() {
        do {
            let snapshots = try store.loadActiveThreadSnapshots()
            let activeIDs = Set(snapshots.map(\.islandSessionID))

            for snapshot in snapshots {
                let alreadyTracked = isSessionTracked?(snapshot.islandSessionID) == true
                    || trackedIslandSessionIDs.contains(snapshot.islandSessionID)
                let events = T3CodeThreadMapper.mapSnapshot(
                    snapshot,
                    previouslyTracked: alreadyTracked
                )
                for event in events {
                    onEvent?(event)
                }
                trackedIslandSessionIDs.insert(snapshot.islandSessionID)
            }

            let vanished = trackedIslandSessionIDs.subtracting(activeIDs)
            for sessionID in vanished {
                onEvent?(T3CodeThreadMapper.mapMissingTrackedSession(sessionID: sessionID))
                trackedIslandSessionIDs.remove(sessionID)
            }
        } catch {
            onStatusMessage?("T3 Code poll failed: \(error.localizedDescription)")
        }
    }
}
