import Foundation

@main
struct LocalHTTPIntegration {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("usage: test PORT game-root") }
        let port = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let server = "http://127.0.0.1:\(port)/"
        UserDefaults.standard.set(server, forKey: RuntimeServerSettings.resourceKey)
        let progress = { (done: Int, total: Int) in
            assert(done <= total)
        }
        try ResourceHotUpdater.clearAllCachedResources()
        let result = try await ResourceVersionUpdater.checkAndInstall(
            gameRoot: root, coreRevision: "2026111703", progress: progress)
        let details = "report=\(result.message), remote=\(result.remoteVersion ?? "nil"), applied=\(result.applied), unverified=\(result.unverified)\n"
        FileHandle.standardError.write(Data(details.utf8))
        assert(result.remoteVersion == "2026112401")
        assert(result.applied == 1)
        assert(result.unchanged == 0)
        assert(result.unverified == 1)
        let hot = ResourceHotUpdater(gameRoot: root, revision: "2026111703")!
        let overlay = hot.activeOverlayRoot(for: "dll/SGCore.swf")
        assert(overlay != nil)
        assert(FileManager.default.fileExists(atPath: overlay!.appendingPathComponent("dll/SGCore.swf").path))
        let result2 = try await ResourceVersionUpdater.checkAndInstall(
            gameRoot: root, coreRevision: "2026111703", progress: progress)
        assert(result2.applied == 0)
        assert(result2.remoteVersion == result.remoteVersion)
        print("PASS: HTTP manifest version check, SHA-256 SWF verification, atomic activation, no redundant download")
    }
}
