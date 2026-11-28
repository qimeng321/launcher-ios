import Foundation

/// The game protocol currently serializes IPv4 addresses into a fixed-width field.
/// Hostnames and IPv6 are intentionally rejected until the socket bridge supports them.
struct LoginEndpoint: Equatable {
    let host: String
    let port: UInt16
    var address: String { "\(host):\(port)" }
}

enum RuntimeServerSettings {
    static let loginKey = "independent.runtime.loginEndpoint.v1"
    private static let unconfiguredSentinel = LoginEndpoint(host: "127.0.0.1", port: 1)

    static var configuredLogin: LoginEndpoint? {
        parseLogin(UserDefaults.standard.string(forKey: loginKey) ?? "")
    }

    static var isLoginConfigured: Bool { configuredLogin != nil }
    static var login: LoginEndpoint { configuredLogin ?? unconfiguredSentinel }

    static func customKey(for gameSlug: String) -> String {
        let safe = String(gameSlug.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
        })
        return "tinplate.game.connection.\(safe)"
    }

    static func parseLogin(_ input: String) -> LoginEndpoint? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let port = UInt16(pieces[1]), port > 0 else { return nil }
        let host = String(pieces[0])
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({
                  $0.count <= 3 && UInt8($0) != nil && String(UInt8($0)!) == String($0)
              }) else { return nil }
        return LoginEndpoint(host: host, port: port)
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
        UserDefaults.standard.set(endpoint.address, forKey: customKey(for: slug))
        UserDefaults.standard.set(endpoint.address, forKey: loginKey)
        return nil
    }

    static func savedCustomAddress(forGameSlug slug: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: customKey(for: slug)),
              parseLogin(value) != nil else { return nil }
        return value
    }

    static func validateResourceURL(_ input: String?) -> URL? {
        guard let input else { return nil }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let c = URLComponents(string: value),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              let decoded = c.percentEncodedPath.removingPercentEncoding,
              !decoded.contains("\\"),
              !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        if let port = c.port, !(1...65535).contains(port) { return nil }
        var normalized = c
        if normalized.percentEncodedPath.isEmpty { normalized.percentEncodedPath = "/" }
        else if !normalized.percentEncodedPath.hasSuffix("/") { normalized.percentEncodedPath += "/" }
        return normalized.url
    }

    static func isAllowedRemoteResourcePath(_ path: String) -> Bool {
        guard let decoded = path.removingPercentEncoding, !decoded.isEmpty, !decoded.hasPrefix("/"),
              !decoded.contains("\\"), !decoded.contains("%"),
              !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let lower = decoded.lowercased()
        let prefixes = ["config/", "resource/", "login/", "dll/", "module/"]
        let extensions: Set<String> = ["swf","xml","json","png","jpg","jpeg","gif","bmp","webp","mp3","mp4","flv","wav","ogg","dat","bin","cfg","ini","txt","css","js","wasm","ttf","otf","woff","woff2","fnt"]
        return prefixes.contains(where: { lower.hasPrefix($0) }) || extensions.contains((lower as NSString).pathExtension)
    }

    static func remoteResourceURL(base: URL, relativePath: String, query: String? = nil) -> URL? {
        guard isAllowedRemoteResourcePath(relativePath),
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let decoded = relativePath.removingPercentEncoding else { return nil }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let path = decoded.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: safe) ?? "" }.joined(separator: "/")
        let prefix = c.percentEncodedPath.isEmpty ? "/" : (c.percentEncodedPath.hasSuffix("/") ? c.percentEncodedPath : c.percentEncodedPath + "/")
        c.percentEncodedPath = prefix + path
        c.percentEncodedQuery = query
        c.fragment = nil
        return c.url
    }

    static func rewriteServerEndpointXML(_ xml: String, endpoint: LoginEndpoint?) -> String {
        guard let endpoint, let regex = try? NSRegularExpression(
            pattern: #"(?i)(<(?:Email|DirSer|Visitor|SubServer|RegistSer)\s+ip=")[^"]*("\\s+port=")[^"]*(")"#
        ) else { return xml }
        return regex.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..<xml.endIndex, in: xml),
            withTemplate: "$1\(endpoint.host)$2\(endpoint.port)$3")
    }

}
