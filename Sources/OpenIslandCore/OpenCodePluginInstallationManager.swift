import Foundation

public struct OpenCodePluginInstallationStatus: Equatable, Sendable {
    public var openCodeConfigDirectory: URL
    public var pluginsDirectory: URL
    public var configURL: URL
    public var pluginFileURL: URL
    public var manifestURL: URL
    public var pluginFilePresent: Bool
    public var pluginRegistered: Bool
    public var manifest: OpenCodePluginInstallerManifest?

    /// OpenCode auto-loads every file under `~/.config/opencode/plugins/`, so the
    /// on-disk plugin file is enough for standalone OpenCode and for OpenChamber's
    /// managed OpenCode (which sets `OPENCODE_CONFIG` but still loads the global
    /// plugins directory).
    public var isInstalled: Bool {
        pluginFilePresent
    }

    public init(
        openCodeConfigDirectory: URL,
        pluginsDirectory: URL,
        configURL: URL,
        pluginFileURL: URL,
        manifestURL: URL,
        pluginFilePresent: Bool,
        pluginRegistered: Bool,
        manifest: OpenCodePluginInstallerManifest?
    ) {
        self.openCodeConfigDirectory = openCodeConfigDirectory
        self.pluginsDirectory = pluginsDirectory
        self.configURL = configURL
        self.pluginFileURL = pluginFileURL
        self.manifestURL = manifestURL
        self.pluginFilePresent = pluginFilePresent
        self.pluginRegistered = pluginRegistered
        self.manifest = manifest
    }
}

public struct OpenCodePluginInstallerManifest: Equatable, Codable, Sendable {
    public static let fileName = "open-island-opencode-plugin-install.json"

    public var pluginPath: String
    public var installedAt: Date

    public init(pluginPath: String, installedAt: Date = .now) {
        self.pluginPath = pluginPath
        self.installedAt = installedAt
    }
}

public final class OpenCodePluginInstallationManager: @unchecked Sendable {
    public static let pluginFileName = "open-island.js"

    public let openCodeConfigDirectory: URL
    private let fileManager: FileManager

    public init(
        openCodeConfigDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.openCodeConfigDirectory = openCodeConfigDirectory
        self.fileManager = fileManager
    }

    private var pluginsDirectory: URL {
        openCodeConfigDirectory.appendingPathComponent("plugins", isDirectory: true)
    }

    private var pluginFileURL: URL {
        pluginsDirectory.appendingPathComponent(Self.pluginFileName)
    }

    /// Canonical OpenCode config (`opencode.json`). Preferred for `plugin` registration.
    private var openCodeJSONURL: URL {
        openCodeConfigDirectory.appendingPathComponent("opencode.json")
    }

    /// Legacy Open Island registration target kept for uninstall / status compat.
    private var legacyConfigURL: URL {
        openCodeConfigDirectory.appendingPathComponent("config.json")
    }

    /// Status reports the canonical config path.
    private var configURL: URL {
        openCodeJSONURL
    }

    private var manifestURL: URL {
        openCodeConfigDirectory.appendingPathComponent(OpenCodePluginInstallerManifest.fileName)
    }

    public func status() throws -> OpenCodePluginInstallationStatus {
        let pluginPresent = fileManager.fileExists(atPath: pluginFileURL.path)
        let registered = isPluginRegistered()
        let manifest = try loadManifest()

        return OpenCodePluginInstallationStatus(
            openCodeConfigDirectory: openCodeConfigDirectory,
            pluginsDirectory: pluginsDirectory,
            configURL: configURL,
            pluginFileURL: pluginFileURL,
            manifestURL: manifestURL,
            pluginFilePresent: pluginPresent,
            pluginRegistered: registered,
            manifest: manifest
        )
    }

    @discardableResult
    public func install(pluginSourceData: Data) throws -> OpenCodePluginInstallationStatus {
        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        // Write the JS plugin file. OpenCode 2 auto-loads every file under
        // `~/.config/opencode/plugins/` (including OpenChamber's managed server).
        // Do NOT register a file:// path in opencode.json — OpenCode 2 warns
        // "configured plugin path must be a directory" and rejects file entries.
        try pluginSourceData.write(to: pluginFileURL, options: .atomic)

        // Remove stale file:// registrations left by older installers.
        try unregisterPluginFromConfig(at: openCodeJSONURL)
        try unregisterPluginFromConfig(at: legacyConfigURL)

        // Write manifest
        let manifest = OpenCodePluginInstallerManifest(pluginPath: pluginFileURL.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        return try status()
    }

    @discardableResult
    public func uninstall() throws -> OpenCodePluginInstallationStatus {
        // Remove plugin file
        if fileManager.fileExists(atPath: pluginFileURL.path) {
            try fileManager.removeItem(at: pluginFileURL)
        }

        // Remove from both canonical and legacy config files
        try unregisterPluginFromConfig(at: openCodeJSONURL)
        try unregisterPluginFromConfig(at: legacyConfigURL)

        // Remove manifest
        if fileManager.fileExists(atPath: manifestURL.path) {
            try fileManager.removeItem(at: manifestURL)
        }

        return try status()
    }

    // MARK: - Config manipulation

    private func pluginFileReference() -> String {
        "file://\(pluginFileURL.path)"
    }

    /// Directory autoload counts as "registered" for OpenCode 2. Stale file://
    /// entries in config files are cleaned on install/uninstall but are not
    /// required for the plugin to load.
    private func isPluginRegistered() -> Bool {
        fileManager.fileExists(atPath: pluginFileURL.path)
    }

    private func unregisterPluginFromConfig(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // OpenCode historically used `plugin`; some tools write `plugins`.
        var changed = false
        for key in ["plugin", "plugins"] {
            guard var plugins = json[key] as? [String] else { continue }
            let before = plugins.count
            let ref = pluginFileReference()
            plugins.removeAll { $0 == ref || $0.hasSuffix("/\(Self.pluginFileName)") }
            guard plugins.count != before else { continue }
            changed = true
            if plugins.isEmpty {
                json.removeValue(forKey: key)
            } else {
                json[key] = plugins
            }
        }

        guard changed else { return }

        try backupFile(at: url)

        let outputData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outputData.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private func loadManifest() throws -> OpenCodePluginInstallerManifest? {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OpenCodePluginInstallerManifest.self, from: data)
    }

    private func backupFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }
}
