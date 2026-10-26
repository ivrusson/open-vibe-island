import Foundation

/// HTTP + SSE client for a running `opencode serve` instance.
public final class OpenCodeServeClient: @unchecked Sendable {
    public let endpoint: OpenCodeServeEndpoint

    private let session: URLSession
    private var eventTask: Task<Void, Never>?
    private let lock = NSLock()

    public var onEvents: (@Sendable ([AgentEvent]) -> Void)?
    public var onStatus: (@Sendable (String) -> Void)?

    public init(endpoint: OpenCodeServeEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    public var isStreaming: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTask != nil
    }

    public func stop() {
        lock.lock()
        eventTask?.cancel()
        eventTask = nil
        lock.unlock()
    }

    // MARK: - Snapshot

    public func listSessions() async throws -> [[String: Any]] {
        let data = try await getJSON(path: "/api/session")
        let root = try JSONSerialization.jsonObject(with: data)
        if let object = root as? [String: Any], let list = object["data"] as? [[String: Any]] {
            return list
        }
        if let list = root as? [[String: Any]] {
            return list
        }
        return []
    }

    public func syncSessionEvents(hostTerminalApp: String = "OpenChamber") async throws -> [AgentEvent] {
        let sessions = try await listSessions()
        return sessions.compactMap {
            OpenCodeServeEventMapper.mapSessionListItem($0, hostTerminalApp: hostTerminalApp)
        }
    }

    // MARK: - SSE

    public func startEventStream(hostTerminalApp: String = "OpenChamber") {
        lock.lock()
        guard eventTask == nil else {
            lock.unlock()
            return
        }
        eventTask = Task { [weak self] in
            await self?.runEventStream(hostTerminalApp: hostTerminalApp)
        }
        lock.unlock()
    }

    private func runEventStream(hostTerminalApp: String) async {
        onStatus?("Connecting to OpenCode SSE…")
        do {
            var request = try authorizedRequest(path: "/global/event")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                onStatus?("OpenCode SSE HTTP \(http.statusCode)")
                clearEventTask()
                return
            }

            onStatus?("Listening to OpenCode events.")
            var dataLines: [String] = []

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if line.hasPrefix(":") {
                    // heartbeat / comment
                    continue
                }
                if line.hasPrefix("data:") {
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    dataLines.append(payload)
                    continue
                }
                if line.isEmpty, !dataLines.isEmpty {
                    let joined = dataLines.joined(separator: "\n")
                    dataLines.removeAll(keepingCapacity: true)
                    emitMapped(jsonText: joined, hostTerminalApp: hostTerminalApp)
                }
            }
        } catch is CancellationError {
            // expected on stop
        } catch {
            onStatus?("OpenCode SSE ended: \(error.localizedDescription)")
        }
        clearEventTask()
    }

    private func emitMapped(jsonText: String, hostTerminalApp: String) {
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let type = (object["type"] as? String)
            ?? ((object["event"] as? [String: Any])?["type"] as? String)
            ?? ""
        let properties = (object["properties"] as? [String: Any])
            ?? (object["data"] as? [String: Any])
            ?? ((object["event"] as? [String: Any])?["properties"] as? [String: Any])
            ?? object
        let events = OpenCodeServeEventMapper.mapSSEEvent(
            type: type,
            properties: properties,
            hostTerminalApp: hostTerminalApp
        )
        if !events.isEmpty {
            onEvents?(events)
        }
    }

    private func clearEventTask() {
        lock.lock()
        eventTask = nil
        lock.unlock()
    }

    // MARK: - HTTP

    private func getJSON(path: String) async throws -> Data {
        let request = try authorizedRequest(path: path)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OpenCodeServeClientError.httpStatus(http.statusCode)
        }
        return data
    }

    private func authorizedRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL)?.absoluteURL else {
            throw OpenCodeServeClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let token = Data("\(endpoint.username):\(endpoint.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

public enum OpenCodeServeClientError: Error, Equatable {
    case invalidURL
    case httpStatus(Int)
}
