import Foundation

@main
struct ManifestTests {
    static func main() throws {
        let hash = String(repeating: "a", count: 64)
        let ok = """
        {"version":"2026112303","requireBase":true,"baseVersion":"2026111703",
        "basePackName":"完整底包","overlayFiles":[
          {"path":"dll/SGCore.swf","size":1234,"sha256":"\(hash)"},
          "resource/item/abc.swf"]}
        """
        let parsed = try ResourceVersionManifest.parse(Data(ok.utf8))
        assert(parsed.version == "2026112303")
        assert(parsed.requireBase)
        assert(parsed.baseVersion == "2026111703")
        assert(parsed.entries.count == 2)
        assert(parsed.entries[0].verified)
        assert(!parsed.entries[1].verified)
        assert(ResourceVersionManifest.allowedFile("version.swf"))
        assert(!ResourceVersionManifest.allowedFile("../../etc/passwd"))
        assert(!ResourceVersionManifest.allowedFile("evil.js"))

        let badInputs = [
          "{\"baseVersion\":\"123\",\"overlayFiles\":[]}",
          "{\"version\":\"bad/../x\"}",
          "{\"version\":\"ok\",\"files\":[\"../etc/passwd\"]}",
          "{\"version\":\"ok\",\"files\":[\"resource/x.swf\",\"resource/x.swf\"]}",
          "{\"version\":\"ok\",\"files\":[{\"path\":\"dll/x.swf\",\"sha256\":\"123\"}]}"
        ]
        for source in badInputs {
            do { _ = try ResourceVersionManifest.parse(Data(source.utf8)); fatalError("Accepted invalid manifest: \(source)") }
            catch is ResourceVersionManifest.ManifestError { continue }
        }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "2026111703\n".write(to: temp.appendingPathComponent(".sg_base_version"), atomically: true, encoding: .utf8)
        assert(ResourceVersionUpdater.localBaseVersion(root: temp, coreRevision: "old") == "2026111703")
        try FileManager.default.removeItem(at: temp.appendingPathComponent(".sg_base_version"))
        try #"{"version":"2026111505","fileCount":40000}"#.write(to: temp.appendingPathComponent(".sg_base_meta.json"), atomically: true, encoding: .utf8)
        assert(ResourceVersionUpdater.localBaseVersion(root: temp, coreRevision: "old") == "2026111505")
        print("PASS: version manifest parsing, integrity requirements and local baseline detection")
    }
}
