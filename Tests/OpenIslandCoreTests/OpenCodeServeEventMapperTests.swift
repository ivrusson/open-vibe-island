import Foundation
import Testing
@testable import OpenIslandCore

struct OpenCodeServeEventMapperTests {
    @Test
    func sessionCreatedMapsToOpenChamberSession() {
        let events = OpenCodeServeEventMapper.mapSSEEvent(
            type: "session.created",
            properties: [
                "info": [
                    "id": "ses_abc",
                    "slug": "stellar-star",
                    "location": ["directory": "/Users/demo/kazi"],
                ] as [String: Any],
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        guard case let .sessionStarted(started)? = events.first else {
            Issue.record("expected sessionStarted")
            return
        }
        #expect(started.sessionID == "opencode-ses_abc")
        #expect(started.tool == .openCode)
        #expect(started.jumpTarget?.terminalApp == "OpenChamber")
        #expect(started.jumpTarget?.workingDirectory == "/Users/demo/kazi")
    }

    @Test
    func promptAdmittedUnwrapsTextObject() {
        let events = OpenCodeServeEventMapper.mapSSEEvent(
            type: "session.next.prompt.admitted",
            properties: [
                "sessionID": "ses_abc",
                "prompt": ["text": "hola mundo"] as [String: Any],
            ],
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(events.contains { event in
            if case let .activityUpdated(update) = event {
                return update.sessionID == "opencode-ses_abc"
                    && update.phase == .running
                    && update.summary.contains("hola mundo")
            }
            return false
        })
        #expect(events.contains { event in
            if case let .openCodeSessionMetadataUpdated(update) = event {
                return update.openCodeMetadata.lastUserPrompt == "hola mundo"
            }
            return false
        })
    }

    @Test
    func executionFailedMapsToCompleted() {
        let events = OpenCodeServeEventMapper.mapSSEEvent(
            type: "session.execution.failed",
            properties: ["sessionID": "ses_abc"],
            now: Date(timeIntervalSince1970: 100)
        )
        guard case let .activityUpdated(update)? = events.first else {
            Issue.record("expected activityUpdated")
            return
        }
        #expect(update.phase == .completed)
    }

    @Test
    func sessionListItemMapsBusy() {
        let event = OpenCodeServeEventMapper.mapSessionListItem([
            "id": "ses_list",
            "location": ["directory": "/tmp/proj"] as [String: Any],
            "status": ["type": "busy"] as [String: Any],
        ])
        guard case let .sessionStarted(started)? = event else {
            Issue.record("expected sessionStarted")
            return
        }
        #expect(started.sessionID == "opencode-ses_list")
        #expect(started.initialPhase == .running)
    }

    @Test
    func sessionListItemSkipsIdleAndCompletedHistory() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(
            OpenCodeServeEventMapper.mapSessionListItem(
                [
                    "id": "ses_idle",
                    "status": ["type": "idle"] as [String: Any],
                    "location": ["directory": "/tmp/proj"] as [String: Any],
                ],
                now: now
            ) == nil
        )
        #expect(
            OpenCodeServeEventMapper.mapSessionListItem(
                [
                    "id": "ses_done",
                    "outcome": ["type": "stop"] as [String: Any],
                    "time": ["updated": 1_700_000_000_000] as [String: Any],
                    "location": ["directory": "/tmp/proj"] as [String: Any],
                ],
                now: now
            ) == nil
        )
        #expect(
            OpenCodeServeEventMapper.mapSessionListItem(
                [
                    "id": "ses_old",
                    "time": [
                        "updated": 1_699_000_000_000,
                        "idle": 1_699_000_100_000,
                    ] as [String: Any],
                    "location": ["directory": "/tmp/proj"] as [String: Any],
                ],
                now: now
            ) == nil
        )
    }

    @Test
    func sessionListItemImportsRecentInFlightWithoutStatus() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let event = OpenCodeServeEventMapper.mapSessionListItem(
            [
                "id": "ses_fresh",
                "title": "Fresh turn",
                "time": ["updated": 1_699_999_000_000] as [String: Any],
                "location": ["directory": "/tmp/proj"] as [String: Any],
            ],
            now: now
        )
        guard case let .sessionStarted(started)? = event else {
            Issue.record("expected sessionStarted for recent in-flight session")
            return
        }
        #expect(started.sessionID == "opencode-ses_fresh")
        #expect(started.initialPhase == .running)
    }
}

struct OpenCodeServeDiscoveryTests {
    @Test
    func parsesOpenChamberManagedDump() {
        let dump = """
        PID  7211
        /Applications/OpenChamber.app/Contents/Resources/opencode-cli/opencode serve --hostname 127.0.0.1 --port 52758 OPENCODE_SERVER_PASSWORD=secret123 OPENCODE_CONFIG=/Users/demo/.config/openchamber/run/instances/1/opencode.managed.json OPENCHAMBER_RUNTIME=desktop __CFBundleIdentifier=dev.openchamber.desktop
        """
        let endpoint = OpenCodeServeDiscovery.endpoint(fromEnvironmentDump: dump, processID: 7211)
        #expect(endpoint?.port == 52758)
        #expect(endpoint?.password == "secret123")
        #expect(endpoint?.isOpenChamberManaged == true)
        #expect(endpoint?.host == "127.0.0.1")
    }
}
