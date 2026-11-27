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
}
