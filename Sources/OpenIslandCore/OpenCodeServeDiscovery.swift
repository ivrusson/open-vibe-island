import Foundation

/// A managed OpenCode HTTP server discovered from a live process (OpenChamber desktop).
public struct OpenCodeServeEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var processID: Int32
    public var isOpenChamberManaged: Bool

    public var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    public init(
        host: String = "127.0.0.1",
        port: Int,
        username: String = "opencode",
        password: String,
        processID: Int32,
        isOpenChamberManaged: Bool
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.processID = processID
        self.isOpenChamberManaged = isOpenChamberManaged
    }
}

public enum OpenCodeServeDiscovery {
    /// Locate OpenChamber-managed `opencode serve` processes.
    ///
    /// - Parameters:
    ///   - candidatePIDs: PIDs to inspect (defaults to `pgrep` for OpenChamber's bundled opencode).
    ///   - processEnvironment: Returns `ps eww -p` style text for a PID (injectable in tests).
    public static func discoverOpenChamberEndpoints(
        candidatePIDs: () -> [Int32] = { Self.defaultCandidatePIDs() },
        processEnvironment: (Int32) -> String = { Self.environmentDump(for: $0) }
    ) -> [OpenCodeServeEndpoint] {
        var endpoints: [OpenCodeServeEndpoint] = []
        for pid in candidatePIDs() {
            let dump = processEnvironment(pid)
            guard let endpoint = endpoint(fromEnvironmentDump: dump, processID: pid),
                  endpoint.isOpenChamberManaged else {
                continue
            }
            endpoints.append(endpoint)
        }
        return endpoints
    }

    /// Parse a single `ps eww -p <pid>` dump into an endpoint when possible.
    public static func endpoint(fromEnvironmentDump dump: String, processID: Int32) -> OpenCodeServeEndpoint? {
        let lowered = dump.lowercased()
        guard lowered.contains("opencode"), lowered.contains("serve") else {
            return nil
        }

        let password = envValue("OPENCODE_SERVER_PASSWORD", in: dump)
            ?? envValue("OPENCODE_PASSWORD", in: dump)
        guard let password, !password.isEmpty else { return nil }

        let port = argumentInt("--port", in: dump) ?? 4096
        let host = argumentString("--hostname", in: dump) ?? "127.0.0.1"
        let username = envValue("OPENCODE_SERVER_USERNAME", in: dump) ?? "opencode"

        let managed = envValue("OPENCODE_CONFIG", in: dump)?.contains("openchamber") == true
            || envValue("OPENCHAMBER_RUNTIME", in: dump) != nil
            || dump.contains("dev.openchamber.desktop")
            || dump.contains("OpenChamber.app")

        return OpenCodeServeEndpoint(
            host: host,
            port: port,
            username: username,
            password: password,
            processID: processID,
            isOpenChamberManaged: managed
        )
    }

    // MARK: - Process helpers

    public static func defaultCandidatePIDs() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "OpenChamber.app/Contents/Resources/opencode-cli/opencode serve"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        } catch {
            return []
        }
    }

    public static func environmentDump(for pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["eww", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Parsing

    private static func envValue(_ key: String, in text: String) -> String? {
        let marker = "\(key)="
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        let value = rest.prefix(while: { $0 != " " && $0 != "\n" })
        let trimmed = String(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func argumentInt(_ name: String, in text: String) -> Int? {
        if let spaced = argumentString(name, in: text), let value = Int(spaced) {
            return value
        }
        return nil
    }

    private static func argumentString(_ name: String, in text: String) -> String? {
        for marker in ["\(name) ", "\(name)="] {
            guard let range = text.range(of: marker) else { continue }
            let rest = text[range.upperBound...]
            let value = rest.prefix(while: { !$0.isWhitespace && $0 != "\n" })
            let trimmed = String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
