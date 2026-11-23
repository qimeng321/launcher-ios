import Foundation

/// Mutable endpoints. They are read when a new game page/socket session starts,
/// not compiled into the IPA. The baseline game files are never edited here.
struct LoginEndpoint: Equatable {
    let host: String
    let port: UInt16
    var address: String { "\(host):\(port)" }
}

enum RuntimeServerSettings {
    static let loginKey = "shiguang.runtime.loginEndpoint.v1"
    static let resourceKey = "shiguang.runtime.resourceBaseURL.v1"
    static let fallbackLogin = LoginEndpoint(host: "202.189.23.85", port: 22973)

    static var login: LoginEndpoint {
        let saved = UserDefaults.standard.string(forKey: loginKey) ?? ""
        return parseLogin(saved) ?? fallbackLogin
    }

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

    /// Returns an explanatory error; never store a half-valid config.
    static func save(loginAddress: String, resourceAddress: String) -> String? {
        guard let login = parseLogin(loginAddress) else {
            return "游戏服请输入有效的 IPv4:端口，例如 202.189.23.85:22973。"
        }
        let value = resourceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let resource = value.isEmpty ? nil : validateResourceURL(value)
        if !value.isEmpty && resource == nil {
            return "资源服请输入完整的 http:// 或 https:// 地址（可以留空以禁用热更新）。"
        }
        UserDefaults.standard.set(login.address, forKey: loginKey)
        UserDefaults.standard.set(resource?.absoluteString ?? "", forKey: resourceKey)
        return nil
    }
}
