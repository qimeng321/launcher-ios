import Foundation

/// Mutable endpoints. They are read when a new game page/socket session starts,
/// not compiled into the IPA. The baseline game files are never edited here.
struct LoginEndpoint: Equatable {
    let host: String
    let port: UInt16
    var address: String { "\(host):\(port)" }
}

enum RuntimeServerSettings {
    static let loginKey = "independent.runtime.loginEndpoint.v1"
    static let resourceKey = "independent.runtime.resourceBaseURL.v1"
    // Real server addresses are never bundled. This loopback sentinel cannot
    // be used for gameplay: canStartGame rejects unset configuration.
    private static let unconfiguredSentinel = LoginEndpoint(host: "127.0.0.1", port: 1)

    static var configuredLogin: LoginEndpoint? {
        parseLogin(UserDefaults.standard.string(forKey: loginKey) ?? "")
    }
    static var isLoginConfigured: Bool { configuredLogin != nil }
    static var login: LoginEndpoint { configuredLogin ?? unconfiguredSentinel }

    /// nil means no online fallback. The resource address must be explicitly
    /// configured; a URL observed in the Windows installer is not proof it is live.
    static var resourceBaseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: resourceKey) else { return nil }
        return validateResourceURL(raw)
    }

    static func parseLogin(_ input: String) -> LoginEndpoint? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let port = UInt16(pieces[1]), port > 0 else { return nil }
        // The game protocol encodes IPs in a fixed 16-byte field. No hostnames
        // or IPv6 until the channel rewrite supports those address families.
        let host = String(pieces[0])
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ $0.count <= 3 && UInt8($0) != nil && String(UInt8($0)!) == String($0) }) else {
            return nil
        }
        return LoginEndpoint(host: host, port: port)
    }


    static func customKey(forGameSlug slug: String) -> String {
        let safe = String(slug.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        })
        return "tinplate.game.connection.\(safe)"
    }

    static func save(loginAddress: String) -> String? {
        let value = loginAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = value.isEmpty ? nil : parseLogin(value)
        if !value.isEmpty && endpoint == nil {
            return "游戏服务器格式错误，请填写 IPv4:端口，或者暂时留空。"
        }
        UserDefaults.standard.set(endpoint?.address ?? "", forKey: loginKey)
        return nil
    }

    static func save(loginAddress: String, forGameSlug slug: String) -> String? {
        let value = loginAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = parseLogin(value) else {
            return "游戏服务器格式错误，请填写 IPv4:端口。"
        }
        UserDefaults.standard.set(endpoint.address, forKey: customKey(forGameSlug: slug))
        UserDefaults.standard.set(endpoint.address, forKey: loginKey)
        return nil
    }

    static func savedCustomAddress(forGameSlug slug: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: customKey(forGameSlug: slug)),
              parseLogin(value) != nil else { return nil }
        return value
    }

    static func validateResourceURL(_ raw: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 500,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        if let port = components.port, port <= 0 || port > 65535 { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: {
            let decoded = String($0).removingPercentEncoding ?? String($0)
            return decoded == ".." || decoded == "." || decoded.contains("\\")
        }) else { return nil }
        components.scheme = scheme
        if !components.path.hasSuffix("/") { components.path += "/" }
        return components.url
    }

    /// Test the URL currently typed on screen without persisting it.
    /// A successful HTTP connection does not imply desktop update compatibility.
    static func testResourceConnection(_ raw: String) async -> String {
        guard let origin = validateResourceURL(raw) else {
            return "请输入完整的 http:// 或 https:// 资源服务器地址。"
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var reachableCode: Int?
        var failureReason: String?
        var request = URLRequest(url: origin)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.compatData(for: request)
            if let http = response as? HTTPURLResponse {
                reachableCode = http.statusCode
            }
        } catch {
            failureReason = error.localizedDescription
        }
        for path in ["_overlay/manifest.json", "manifest.json"] {
            let candidate = origin.appendingPathComponent(path)
            var probe = URLRequest(url: candidate)
            probe.cachePolicy = .reloadIgnoringLocalCacheData
            probe.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.compatData(for: probe)
                guard let http = response as? HTTPURLResponse else { continue }
                if reachableCode == nil { reachableCode = http.statusCode }
                guard (200...299).contains(http.statusCode),
                      data.count <= 4 * 1_048_576 else { continue }
                if let manifest = try? ResourceVersionManifest.parse(data) {
                    let verifiedCount = manifest.entries.filter { $0.verified }.count
                    return "连接成功（HTTP \(http.statusCode)）。识别远程版本 \(manifest.version)，清单文件 \(manifest.entries.count) 个，其中 SHA-256 可校验 \(verifiedCount) 个。请返回首页点“检查更新”；此处仅测试，不下载资源。"
                }
            } catch {
                if failureReason == nil { failureReason = error.localizedDescription }
            }
        }
        if let code = reachableCode {
            return "资源服务器已响应（HTTP \(code)），但未找到 iOS 支持的版本清单。电脑端可能使用不同更新协议；可按需补齐缺失资源，不代表已同步电脑端更新。"
        }
        return "连接失败：\(failureReason ?? "服务器无响应或网络不可用")。请核对 IP、端口和网络连接。"
    }

    /// Returns an explanatory error; never store a half-valid config.
    static func save(loginAddress: String, resourceAddress: String) -> String? {
        let game = loginAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = game.isEmpty ? nil : parseLogin(game)
        if !game.isEmpty && login == nil {
            return "游戏服格式错误，请填写 IPv4:端口，或者暂时留空。"
        }
        let value = resourceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let resource = value.isEmpty ? nil : validateResourceURL(value)
        if !value.isEmpty && resource == nil {
            return "资源服请输入完整的 http:// 或 https:// 地址（可以留空以禁用热更新）。"
        }
        UserDefaults.standard.set(login?.address ?? "", forKey: loginKey)
        UserDefaults.standard.set(resource?.absoluteString ?? "", forKey: resourceKey)
        return nil
    }
}


// Native URLSession async methods first appeared in iOS 15; the completion
// handler variants and Swift concurrency back-deployment work on iOS 14.
extension URLSession {
    func compatData(for request: URLRequest) async throws -> (Data, URLResponse) {
        if #available(iOS 15.0, *) { return try await data(for: request) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            dataTask(with: request) { bytes, response, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let bytes = bytes, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                continuation.resume(returning: (bytes, response))
            }.resume()
        }
    }
    func compatDownload(for request: URLRequest) async throws -> (URL, URLResponse) {
        if #available(iOS 15.0, *) { return try await download(for: request) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            downloadTask(with: request) { location, response, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let location = location, let response = response else {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                do {
                    let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    // URLSession removes the original as soon as this callback returns.
                    try FileManager.default.moveItem(at: location, to: saved)
                    continuation.resume(returning: (saved, response))
                } catch { continuation.resume(throwing: error) }
            }.resume()
        }
    }
}
