import Foundation
import Testing
@testable import OpenIslandCore

struct T3CodeThreadMapperTests {
    @Test
    func mapsRunningCursorThread() {
        let snapshot = T3CodeThreadSnapshot(
            threadID: "02641fb6-bd07-4186-adb7-114966e4b65c",
            title: "Open Chamber Integration",
            projectTitle: "open-vibe-island",
            workspacePath: "/Users/demo/.t3/worktrees/open-vibe-island/feat",
            provider: "cursor",
            runStatus: "running"
        )

        let events = T3CodeThreadMapper.mapSnapshot(snapshot, previouslyTracked: false)
        guard case let .sessionStarted(started)? = events.first else {
            Issue.record("expected sessionStarted")
            return
        }
        #expect(started.sessionID == "t3-02641fb6-bd07-4186-adb7-114966e4b65c")
        #expect(started.tool == .cursor)
        #expect(started.jumpTarget?.terminalApp == "T3 Code")
        #expect(started.initialPhase == .running)
    }

    @Test
    func mapsWaitingAsPermission() {
        let snapshot = T3CodeThreadSnapshot(
            threadID: "thread-1",
            title: "Needs approval",
            workspacePath: "/tmp/proj",
            provider: "claudeAgent",
            runStatus: "waiting",
            pendingApprovalCount: 1
        )
        let events = T3CodeThreadMapper.mapSnapshot(snapshot, previouslyTracked: true)
        #expect(events.contains { event in
            if case .permissionRequested = event { return true }
            return false
        })
        #expect(T3CodeThreadMapper.agentTool(forProvider: "claudeAgent") == .claudeCode)
    }

    @Test
    func skipsDuplicateSessionStartedWhenTracked() {
        let snapshot = T3CodeThreadSnapshot(
            threadID: "thread-2",
            title: "Again",
            provider: "codex",
            runStatus: "running"
        )
        let events = T3CodeThreadMapper.mapSnapshot(snapshot, previouslyTracked: true)
        #expect(!events.contains { if case .sessionStarted = $0 { return true }; return false })
        #expect(events.contains { if case .activityUpdated = $0 { return true }; return false })
    }
}
