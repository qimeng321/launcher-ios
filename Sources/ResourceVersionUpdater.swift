import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

struct ResourceUpdateReport {
    let localBaseVersion: String
    let remoteVersion: String?
    let applied: Int
    let unchanged: Int
    let unverified: Int
    let message: String
}

/// Maintains immutable generations. A fully verified generation is activated by
/// a final atomic pointer write. Source .srom and mobile patch files remain intact.
/// Missing-only fallback remains in ResourceHotUpdater when no manifest is found.
enum ResourceVersionUpdater {
    enum UpdateError: LocalizedError {
        case invalidHTTP, invalidManifest, incompatibleBase(expected: String, local: String), downloadInvalid(String), invalidData(String)
        var errorDescription: String? {
            switch self {
            case .invalidHTTP: return "资源服务器没有返回可用版本清单"
            case .invalidManifest: return "资源版本清单超过大小限制或格式不受支持"
            case .incompatibleBase(let expected, let local): return "资源清单要求底包 \(expected)，当前底包为 \(local)；已跳过不兼容更新"
            case .downloadInvalid(let path): return "资源下载或校验失败：\(path)"
            case .invalidData(let reason): return reason
            }
        }
    }

    private struct ActivatedIndex: Codable {
        let version: String
        let folder: String
        let files: [String]
        let verifiedFiles: [String]
        let fingerprint: String
    }
    private static let indexName = "active-version.json"
    private static let maxManifestSize = 4 * 1_048_576
    private static let maxDownloadedPerUpdate: Int64 = 3 * 1024 * 1024 * 1024

    static func localBaseVersion(root: URL, coreRevision: String?) -> String {
        let manager = FileManager.default
        for file in [".sg_base_version", "base.version"] {
            let url = root.appendingPathComponent(file)
            if let raw = try? String(contentsOf: url, encoding: .utf8) {
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if ResourceVersionManifest.safeLabel(text) != nil { return text }
            }
        }
        let metaURL = root.appendingPathComponent(".sg_base_meta.json")
        if let data = manager.contents(atPath: metaURL.path), data.count <= 256 * 1024,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String,
           ResourceVersionManifest.safeLabel(version) != nil { return version }
        if let coreRevision, ResourceVersionManifest.safeLabel(coreRevision) != nil { return coreRevision }
        return "unknown"
    }

    private static func validIndex(cacheRoot: URL) -> (ActivatedIndex, URL)? {
        guard let data = try? Data(contentsOf: cacheRoot.appendingPathComponent(indexName)),
              data.count < 3 * 1_048_576,
              let index = try? JSONDecoder().decode(ActivatedIndex.self, from: data),
              ResourceVersionManifest.safeLabel(index.version) != nil,
              ResourceVersionManifest.safeLabel(index.folder) != nil,
              index.files.count <= 20_000 && index.verifiedFiles.count <= 20_000,
              index.files.allSatisfy({ ResourceVersionManifest.allowedFile($0) }),
              index.verifiedFiles.allSatisfy({ ResourceVersionManifest.allowedFile($0) }),
              Set(index.files).isSubset(of: Set(index.verifiedFiles)) else { return nil }
        let folder = cacheRoot.appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent(index.folder, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        return (index, folder)
    }

    /// Each game session snapshots the active resources once; a later update
    /// takes effect only after leaving and re-entering the game.
    static func activeOverlay(cacheRoot: URL) -> (root: URL, files: Set<String>, verifiedFiles: Set<String>, version: String)? {
        guard let (index, folder) = validIndex(cacheRoot: cacheRoot) else { return nil }
        return (folder, Set(index.files), Set(index.verifiedFiles), index.version)
    }

    private static func checkedURL(_ base: URL, path: String) -> URL {
        var url = base
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    private static func checkHTTP(_ response: URLResponse, expectedOrigin: URL) -> Bool {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let final = response.url,
              final.scheme?.lowercased() == expectedOrigin.scheme?.lowercased(),
              final.host?.lowercased() == expectedOrigin.host?.lowercased(),
              (final.port ?? (final.scheme == "https" ? 443 : 80)) ==
                (expectedOrigin.port ?? (expectedOrigin.scheme == "https" ? 443 : 80)) else { return false }
        return true
    }

    private static func fingerprint(_ data: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #elseif os(Linux)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("version-digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        return try linuxSHA256(file)
        #else
        throw UpdateError.invalidData("当前平台不支持 SHA-256 校验；停止更新")
        #endif
    }

    #if os(Linux)
    private static func linuxSHA256(_ file: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
        process.arguments = [file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let first = String(data: output, encoding: .utf8)?.split(separator: " ").first,
              first.count == 64 else { throw UpdateError.invalidData("Linux 测试环境 SHA-256 失败") }
        return String(first)
    }
    #endif

    private static func sha256(_ file: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #elseif os(Linux)
        return try linuxSHA256(file)
        #else
        throw UpdateError.invalidData("当前平台不支持 SHA-256 校验；停止更新")
        #endif
    }

    private static func resourceSignatureValid(file: URL, path: String) -> Bool {
        let low = path.lowercased()
        guard low.hasSuffix(".swf") else { return true }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        let data = (try? handle.read(upToCount: 3)) ?? Data()
        try? handle.close()
        let sig = String(data: data, encoding: .ascii) ?? ""
        return ["FWS", "CWS", "ZWS"].contains(sig) || (low == "version.swf" && data.starts(with: [0x4b, 0x50]))
    }

    static func checkAndInstall(gameRoot: URL, coreRevision: String?,
                                progress: @escaping (Int, Int) -> Void) async throws -> ResourceUpdateReport {
        let localVersion = localBaseVersion(root: gameRoot, coreRevision: coreRevision)
        guard let updater = ResourceHotUpdater(gameRoot: gameRoot, revision: coreRevision),
              let origin = RuntimeServerSettings.resourceBaseURL else {
            return ResourceUpdateReport(localBaseVersion: localVersion, remoteVersion: nil,
                                        applied: 0, unchanged: 0, unverified: 0,
                                        message: "资源服务器未设置；使用本地底包")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 3
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // Probe only known conventions; Windows _overlay/manifest.json was
        // observed as a LOCAL endpoint, not proven to be hosted remotely.
        var remoteManifest: ResourceVersionManifest?
        var remoteManifestBytes: Data?
        for path in ["_overlay/manifest.json", "manifest.json"] {
            var request = URLRequest(url: checkedURL(origin, path: path))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                guard checkHTTP(response, expectedOrigin: origin), data.count <= maxManifestSize else { continue }
                if let manifest = try? ResourceVersionManifest.parse(data) {
                    remoteManifest = manifest
                    remoteManifestBytes = data
                    break
                }
            } catch { continue }
        }
        guard let manifest = remoteManifest else {
            return ResourceUpdateReport(localBaseVersion: localVersion, remoteVersion: nil,
                                        applied: 0, unchanged: 0, unverified: 0,
                                        message: "资源服没有可识别的远程版本清单；仍可按需补齐缺失资源，不覆盖已有文件")
        }
        if manifest.requireBase, let expected = manifest.baseVersion,
           expected != localVersion {
            throw UpdateError.incompatibleBase(expected: expected, local: localVersion)
        }
        if manifest.requireBase && localVersion == "unknown" {
            throw UpdateError.incompatibleBase(expected: manifest.baseVersion ?? "已安装的有效底包",
                                               local: localVersion)
        }
        guard let manifestData = remoteManifestBytes else { throw UpdateError.invalidManifest }
        let manifestFingerprint = try fingerprint(manifestData)
                let unverified = manifest.entries.filter { !$0.verified }.count
        let verified = manifest.entries.filter { $0.verified }
        guard verified.count <= 20_000 else { throw UpdateError.invalidManifest }
        let activeIndex = validIndex(cacheRoot: updater.cacheRoot)
        if let (active, _) = activeIndex,
           active.version == manifest.version && active.fingerprint == manifestFingerprint,
           active.files.allSatisfy({ path in verified.contains(where: { $0.path == path }) }) {
            return ResourceUpdateReport(localBaseVersion: localVersion, remoteVersion: manifest.version,
                                        applied: 0, unchanged: verified.count, unverified: unverified,
                                        message: "资源版本 \(manifest.version) 已检查，当前已是缓存版本")
        }
        let manager = FileManager.default
        let generations = updater.cacheRoot.appendingPathComponent("versions", isDirectory: true)
        try manager.createDirectory(at: generations, withIntermediateDirectories: true)
        let folderName = "gen-" + UUID().uuidString
        let staging = generations.appendingPathComponent(folderName, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var activated: [String] = []
        var unchanged = 0
        var downloaded = 0
        var totalDownloaded: Int64 = 0
        var completed = false
        defer { if !completed { try? manager.removeItem(at: staging) } }
        progress(0, verified.count)
        for (index, entry) in verified.enumerated() {
            guard let expectedHash = entry.sha256 else { continue }
            // Hash must match. Equal filename or equal byte count is not a valid
            // update check. If the baseline already has correct content, reuse it.
            let existing = gameRoot.appendingPathComponent(entry.path)
            if (try? existing.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
               (try? sha256(existing)) == expectedHash {
                unchanged += 1
                progress(index + 1, verified.count)
                continue
            }
            if let expectedSize = entry.size,
               expectedSize > maxDownloadedPerUpdate - totalDownloaded {
                throw UpdateError.invalidData("单次更新总下载量超过 3 GiB 限制，已保留原版本")
            }
            let remoteURL = checkedURL(origin, path: entry.path)
            var request = URLRequest(url: remoteURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (tmp, response) = try await session.download(for: request)
            guard checkHTTP(response, expectedOrigin: origin),
                  let attrs = try? manager.attributesOfItem(atPath: tmp.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size > 0, size <= ResourceHotUpdater.maxAssetBytes,
                  entry.size == nil || entry.size == size,
                  size <= maxDownloadedPerUpdate - totalDownloaded,
                  resourceSignatureValid(file: tmp, path: entry.path),
                  (try? sha256(tmp)) == expectedHash else {
                throw UpdateError.downloadInvalid(entry.path)
            }
            let target = staging.appendingPathComponent(entry.path)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: tmp, to: target)
            downloaded += 1
            totalDownloaded += size
            activated.append(entry.path)
            progress(index + 1, verified.count)
        }
        // Replacing this one small pointer is the commit point: if any download
        // fails or the app terminates, the previous generation remains active.
        let index = ActivatedIndex(version: manifest.version, folder: folderName,
                                   files: activated, verifiedFiles: verified.map(\.path),
                                   fingerprint: manifestFingerprint)
        let bytes = try JSONEncoder().encode(index)
        try bytes.write(to: updater.cacheRoot.appendingPathComponent(indexName), options: .atomic)
        completed = true
        let skipped = unverified > 0 ? "，\(unverified) 个无 SHA-256 资源仅保留按需补齐" : ""
        return ResourceUpdateReport(localBaseVersion: localVersion, remoteVersion: manifest.version,
                                    applied: downloaded, unchanged: unchanged, unverified: unverified,
                                    message: "版本 \(localVersion) → \(manifest.version)：已校验并缓存 \(downloaded) 个变更资源\(skipped)，下次进入游戏生效")
    }
}
