import Foundation
import Testing
@testable import OpenIslandCore

struct OpenCodePluginInstallationManagerTests {
    @Test
    func installWritesPluginFileAndClearsStaleFileURLRegistration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-opencode-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existingOpenCodeJSON = """
        {
          "$schema" : "https://opencode.ai/config.json",
          "plugin" : ["file://\(root.path)/plugins/open-island.js"]
        }
        """.data(using: .utf8)!
        try existingOpenCodeJSON.write(to: root.appendingPathComponent("opencode.json"))

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: root)
        let pluginSource = Data("// open-island test plugin\n".utf8)
        let status = try manager.install(pluginSourceData: pluginSource)

        #expect(status.isInstalled)
        #expect(status.pluginFilePresent)
        #expect(status.pluginRegistered)
        #expect(FileManager.default.fileExists(atPath: status.pluginFileURL.path))

        let configData = try Data(contentsOf: root.appendingPathComponent("opencode.json"))
        let json = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        let plugins = json["plugin"] as? [String] ?? []
        #expect(plugins.contains { $0.hasSuffix("/open-island.js") } == false)
    }

    @Test
    func pluginFileAloneCountsAsInstalledForDirectoryAutoload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-opencode-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data("// dropped into plugins/\n".utf8)
            .write(to: plugins.appendingPathComponent("open-island.js"))

        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: root)
        let status = try manager.status()

        #expect(status.pluginFilePresent)
        #expect(status.isInstalled)
        // OpenCode 2 directory autoload: the on-disk file is the registration.
        #expect(status.pluginRegistered)
    }

    @Test
    func uninstallRemovesPluginFileAndOpenCodeJSONRegistration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-island-opencode-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = OpenCodePluginInstallationManager(openCodeConfigDirectory: root)
        _ = try manager.install(pluginSourceData: Data("// plugin\n".utf8))
        let status = try manager.uninstall()

        #expect(status.pluginFilePresent == false)
        #expect(status.isInstalled == false)
        #expect(status.pluginRegistered == false)
    }
}
