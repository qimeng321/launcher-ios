import Foundation
#if canImport(Network)
import Network
#endif

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

    /// The universal launcher only uses local resources.
    static var resourceBaseURL: URL? { nil }

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

    static func rewriteLoginXML(_ xml: String, endpoint: LoginEndpoint) -> String {
        guard let tags = try? NSRegularExpression(pattern: #"(?i)<(?:Email|DirSer|Visitor|SubServer|RegistSer|LoginServer)\b[^<>]*>"#),
              let ip = try? NSRegularExpression(pattern: #"(?i)(\bip\s*=\s*["'])[^"']*(["'])"#),
              let port = try? NSRegularExpression(pattern: #"(?i)(\bport\s*=\s*["'])[^"']*(["'])"#) else { return xml }
        var output = xml
        for match in tags.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            var tag = String(output[range])
            let span = NSRange(tag.startIndex..., in: tag)
            guard ip.firstMatch(in: tag, range: span) != nil,
                  port.firstMatch(in: tag, range: span) != nil else { continue }
            for (regex, value) in [(ip, endpoint.host), (port, String(endpoint.port))] {
                for hit in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)).reversed() {
                    guard let whole = Range(hit.range, in: tag),
                          let prefix = Range(hit.range(at: 1), in: tag),
                          let suffix = Range(hit.range(at: 2), in: tag) else { continue }
                    let replacement = String(tag[prefix]) + value + String(tag[suffix])
                    tag.replaceSubrange(whole, with: replacement)
                }
            }
            output.replaceSubrange(range, with: tag)
        }
        return output
    }

    #if canImport(Network)
    static func testLoginConnection(_ raw: String) async -> String {
        guard let endpoint = parseLogin(raw),
              let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            return "请输入有效的 IPv4:端口。"
        }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "launcher.login.probe")
            let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
            var finished = false
            func complete(_ message: String) {
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: message)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: complete("TCP 连接成功；仍需实际登录验证游戏兼容性。")
                case .failed(let error): complete("连接失败：" + error.localizedDescription)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 8) { complete("连接超时；请检查服务器状态和网络。") }
            connection.start(queue: queue)
        }
    }
    #endif

    static func save(loginAddress: String, resourceAddress: String = "") -> String? {
        let game = loginAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = game.isEmpty ? nil : parseLogin(game)
        if !game.isEmpty && login == nil {
            return "游戏服格式错误，请填写 IPv4:端口，或者暂时留空。"
        }
        UserDefaults.standard.set(login?.address ?? "", forKey: loginKey)
        UserDefaults.standard.removeObject(forKey: resourceKey)
        return nil
    }
}
