import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lazy resource completion: packaged game -> verified disk cache -> remote URL.
/// Never mutates the original .srom installation or the active mobile patch.
/// A remote manifest is not assumed: unknown Windows update protocols must not
/// be silently fabricated. Only files actually requested by the game are fetched.
final class ResourceHotUpdater {
    enum DownloadFailure: LocalizedError {
        case invalidPath, noResourceServer, invalidResponse, tooLarge, invalidAsset
        var errorDescription: String? {
            switch self {
            case .invalidPath: return "非法资源路径"
            case .noResourceServer: return "资源服务器未设置"
            case .invalidResponse: return "资源服未返回有效文件 (HTTP/跳转失败)"
            case .tooLarge: return "资源文件超过 80 MiB 限制"
            case .invalidAsset: return "资源内容校验失败"
            }
        }
    }

    static let maxAssetBytes: Int64 = 80 * 1_048_576
    private static let rootFolderName = "ResourceHotCache"
    private let endpoint: URL
    let cacheRoot: URL
    private let session: URLSession
    private let lock = NSLock()
    private var pending: [String: [(Result<URL, Error>) -> Void]] = [:]
    private let activatedOverlay: (root: URL, files: Set<String>, verifiedFiles: Set<String>, version: String)?
    let lazyCacheRoot: URL

    private static func supportDirectory() -> URL {
        #if RESOURCE_UPDATE_TEST
        if let location = ProcessInfo.processInfo.environment["RESOURCE_UPDATE_TEST_CACHE_ROOT"],
           !location.isEmpty { return URL(fileURLWithPath: location, isDirectory: true) }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    init?(gameRoot: URL, revision: String?) {
        guard let endpoint = RuntimeServerSettings.resourceBaseURL else { return nil }
        self.endpoint = endpoint
        let safeRevision = (revision ?? "unknown").filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let revisionFolder = safeRevision.isEmpty ? "unknown" : String(safeRevision.prefix(72))
        let appSupport = Self.supportDirectory()
        // Isolate different resource origins even when they advertise the
        // same game revision. A server switch must never reuse old-host files.
        var originFingerprint: UInt64 = 14_695_981_039_346_656_037
        for byte in endpoint.absoluteString.utf8 {
            originFingerprint = (originFingerprint ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let originFolder = String(originFingerprint, radix: 16)
        self.cacheRoot = appSupport.appendingPathComponent(Self.rootFolderName, isDirectory: true)
            .appendingPathComponent(revisionFolder, isDirectory: true)
            .appendingPathComponent(originFolder, isDirectory: true)
        // Snapshot the active version for this game session. Do not reload a
        // potentially large manifest JSON on every HTTP asset request.
        self.activatedOverlay = ResourceVersionUpdater.activeOverlay(cacheRoot: self.cacheRoot)
        let lazyRevision = self.activatedOverlay?.version ?? "pre-manifest"
        self.lazyCacheRoot = self.cacheRoot.appendingPathComponent("lazy", isDirectory: true)
            .appendingPathComponent(lazyRevision, isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 90
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    static func clearAllCachedResources() throws {
        let base = supportDirectory().appendingPathComponent(rootFolderName, isDirectory: true)
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
    }

    /// Allow only game resource directories. Reject traversal and URL metacharacters.
    static func isAllowedResource(_ relative: String) -> Bool {
        guard !relative.isEmpty, relative.count <= 700,
              !relative.hasPrefix("/"), !relative.contains("\\"), !relative.contains("?"),
              !relative.contains("#"), !relative.contains(":"), !relative.contains("%") else { return false }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1 && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return ["resource", "module", "config", "dll", "login", "assets", "ext", "flash", "images", "nono"].contains(String(parts[0]).lowercased())
    }

    /// A downloaded update generation is read only after an atomic activation.
    func activeOverlayRoot(for relative: String) -> URL? {
        guard let active = activatedOverlay, active.files.contains(relative) else { return nil }
        let file = active.root.appendingPathComponent(relative)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return active.root
    }

    /// A verified manifest may declare the ORIGINAL base file correct. In that
    /// case an older mobile patch must not override it.
    func preferVerifiedBaseline(for relative: String) -> Bool {
        guard let current = activatedOverlay else { return false }
        return current.verifiedFiles.contains(relative) && !current.files.contains(relative)
    }

    func cachedFile(_ relative: String) -> URL? {
        guard Self.isAllowedResource(relative) else { return nil }
        let file = lazyCacheRoot.appendingPathComponent(relative)
        guard file.standardizedFileURL.path.hasPrefix(lazyCacheRoot.standardizedFileURL.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return file
    }

    func fetch(_ relative: String, completion: @escaping (Result<URL, Error>) -> Void) {
        guard Self.isAllowedResource(relative) else { completion(.failure(DownloadFailure.invalidPath)); return }
        if let cached = cachedFile(relative) { completion(.success(cached)); return }
        lock.lock()
        if pending[relative] != nil {
            pending[relative]?.append(completion)
            lock.unlock()
            return
        }
        pending[relative] = [completion]
        lock.unlock()

        // URL.appendingPathComponent encodes each segment; the path has already
        // been checked so the remote host cannot be changed by an asset request.
        var remote = endpoint
        for segment in relative.split(separator: "/") {
            remote.appendPathComponent(String(segment), isDirectory: false)
        }
        var request = URLRequest(url: remote)
        request.httpMethod = "GET"
        request.setValue("application/octet-stream, */*", forHTTPHeaderField: "Accept")
        session.downloadTask(with: request) { [weak self] temporary, response, error in
            guard let self else { return }
            let result: Result<URL, Error>
            do {
                if let error { throw error }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.host?.lowercased() == self.endpoint.host?.lowercased() else {
                    throw DownloadFailure.invalidResponse
                }
                guard http.expectedContentLength < 0 || http.expectedContentLength <= Self.maxAssetBytes else {
                    throw DownloadFailure.tooLarge
                }
                guard let temporary else { throw DownloadFailure.invalidResponse }
                let attrs = try FileManager.default.attributesOfItem(atPath: temporary.path)
                let n = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                guard n > 0, n <= Self.maxAssetBytes else { throw DownloadFailure.tooLarge }
                if relative.lowercased().hasSuffix(".swf") {
                    let handle = try FileHandle(forReadingFrom: temporary)
                    let signature = try handle.read(upToCount: 3) ?? Data()
                    try? handle.close()
                    guard ["CWS", "FWS", "ZWS"].contains(String(data: signature, encoding: .ascii) ?? "") else {
                        throw DownloadFailure.invalidAsset
                    }
                }
                let final = self.lazyCacheRoot.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: final.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                // Keep the baseline untouched. An atomic, same-volume rename
                // ensures Flash never receives a half-downloaded resource.
                let staging = final.appendingPathExtension("part-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: temporary, to: staging)
                if !FileManager.default.fileExists(atPath: final.path) {
                    try FileManager.default.moveItem(at: staging, to: final)
                } else {
                    try? FileManager.default.removeItem(at: staging)
                }
                result = .success(final)
            } catch { result = .failure(error) }
            self.lock.lock()
            let callbacks = self.pending.removeValue(forKey: relative) ?? []
            self.lock.unlock()
            for callback in callbacks { callback(result) }
        }.resume()
    }
}
