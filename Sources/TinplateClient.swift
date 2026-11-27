import SwiftUI
import Foundation
import Combine
import Security
import UIKit

// MARK: - Tinplate API models

struct TinplateAccount: Codable {
    let id: String
    let username: String
    let displayName: String?
}

struct TinplateAuthResponse: Codable {
    let account: TinplateAccount
    let token: String
    let recoveryCode: String?
}

struct TinplateGame: Codable, Identifiable, Hashable {
    let id: String
    let slug: String
    let name: String
    let description: String?
    let iconFileId: String?
    let defaultHost: String?
    let defaultPort: Int?
    let resourceVersions: [String]?
    let clientVersions: [String]?
    let adaptationStatus: String?
    let maintenanceNotice: String?
    let updatedAt: String?
}

struct TinplateGameListResponse: Codable {
    let games: [TinplateGame]
}

struct TinplateConnection: Codable {
    let host: String
    let port: Int
}

struct TinplateConnectionResponse: Codable {
    let success: Bool
    let gameId: String
    let gameSlug: String
    let defaultConnection: TinplateConnection
    let updatedAt: String?
}

struct TinplateDeviceResponse: Codable {
    struct Device: Codable { let id: String }
    let success: Bool
    let device: Device
}

private struct TinplateAPIErrorBody: Decodable {
    let code: String?
    let message: String?
    let error: String?
}

struct TinplateClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Session token storage

enum TinplateTokenVault {
    private static let service = "cn.qimeng321.tinplate"
    private static let account = "client-session"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        delete()
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - API client and account state

@MainActor
final class TinplateClientModel: ObservableObject {
    static let baseURLKey = "tinplate.server.baseURL.v1"
    static let selectedGameKey = "tinplate.selectedGame.slug.v1"
    static let deviceRandomIDKey = "tinplate.device.randomID.v1"
    static let launcherVersion = "1.0.150"
    static let ruffleVersion = "nightly-2026-11-13"

    @Published var serverAddress = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
    @Published var username = UserDefaults.standard.string(forKey: "tinplate.account.username") ?? ""
    @Published var games: [TinplateGame] = []
    @Published var selectedGameSlug = UserDefaults.standard.string(forKey: selectedGameKey)
    @Published private(set) var account: TinplateAccount?
    @Published private(set) var isAuthenticated = false
    @Published var isBusy = false
    @Published var status = "请配置小铁皮服务端地址"
    @Published private(set) var recoveryCode: String?
    @Published private(set) var serverDeviceID: String?

    private var token: String?
    private let session: URLSession

    init() {
        let savedBase = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? ""
        let tokenBase = UserDefaults.standard.string(forKey: "tinplate.token.serverAddress") ?? ""
        if tokenBase.isEmpty || tokenBase != savedBase {
            TinplateTokenVault.delete()
            UserDefaults.standard.removeObject(forKey: "tinplate.token.serverAddress")
        }
        token = TinplateTokenVault.read()
        isAuthenticated = token != nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    var selectedGame: TinplateGame? {
        games.first(where: { $0.slug == selectedGameSlug })
    }

    private func validatedBaseURL() throws -> URL {
        let value = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw TinplateClientError(message: "请输入有效的小铁皮服务端地址，例如 https://你的域名")
        }
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw TinplateClientError(message: "账号和令牌必须通过 HTTPS 传输。正式服务器请配置 HTTPS 域名。")
        }
        guard let url = components.url else {
            throw TinplateClientError(message: "服务端地址格式无效")
        }
        return url
    }

    func saveServerAddress() throws {
        let url = try validatedBaseURL()
        let normalized = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let previousBase = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? ""
        if normalized != previousBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")), token != nil {
            token = nil
            account = nil
            isAuthenticated = false
            serverDeviceID = nil
            TinplateTokenVault.delete()
            UserDefaults.standard.removeObject(forKey: "tinplate.token.serverAddress")
        }
        serverAddress = normalized
        UserDefaults.standard.set(serverAddress, forKey: Self.baseURLKey)
        status = "服务端地址已保存"
    }

    private func makeURL(path: String) throws -> URL {
        let base = try validatedBaseURL()
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw TinplateClientError(message: "无法构造服务端请求地址")
        }
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [prefix, "api", "v1", suffix].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw TinplateClientError(message: "服务端请求地址无效")
        }
        return url
    }

    private func encodeBody(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func request<T: Decodable>(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        authenticated: Bool = true,
        as type: T.Type = T.self
    ) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if authenticated {
            throw TinplateClientError(message: "请先登录小铁皮账号")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TinplateClientError(message: "服务端没有返回有效 HTTP 响应")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(TinplateAPIErrorBody.self, from: data)
            if http.statusCode == 401 {
                token = nil
                isAuthenticated = false
                TinplateTokenVault.delete()
            }
            let message = body?.message ?? body?.error ?? body?.code ?? "HTTP \(http.statusCode)"
            throw TinplateClientError(message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TinplateClientError(message: "服务端响应格式与客户端接口定义不一致：\(error.localizedDescription)")
        }
    }

    private func applyAuthentication(_ response: TinplateAuthResponse) async {
        token = response.token
        TinplateTokenVault.write(response.token)
        UserDefaults.standard.set(serverAddress, forKey: "tinplate.token.serverAddress")
        account = response.account
        username = response.account.username
        isAuthenticated = true
        UserDefaults.standard.set(username, forKey: "tinplate.account.username")
        recoveryCode = response.recoveryCode
        status = "已登录：\(account?.username ?? username)"
        await registerDevice()
        await loadGames()
    }

    func clearRecoveryCode() { recoveryCode = nil }

    func register(password: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try saveServerAddress()
            let body = try encodeBody(["username": username, "password": password])
            let response: TinplateAuthResponse = try await request(
                "account/register", method: "POST", body: body, authenticated: false
            )
            await applyAuthentication(response)
            if recoveryCode != nil { status = "注册成功，请立即保存一次性恢复码" }
        } catch {
            status = "注册失败：\(error.localizedDescription)"
        }
    }

    func login(password: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try saveServerAddress()
            let body = try encodeBody(["username": username, "password": password])
            let response: TinplateAuthResponse = try await request(
                "account/login", method: "POST", body: body, authenticated: false
            )
            await applyAuthentication(response)
        } catch {
            status = "登录失败：\(error.localizedDescription)"
        }
    }

    func logout() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        if token != nil {
            struct EmptyResponse: Decodable {}
            _ = try? await request("account/me", method: "DELETE", as: EmptyResponse.self)
        }
        token = nil
        account = nil
        isAuthenticated = false
        serverDeviceID = nil
        TinplateTokenVault.delete()
        UserDefaults.standard.removeObject(forKey: "tinplate.token.serverAddress")
        status = "已退出小铁皮账号"
    }

    func restoreSession() async {
        guard token != nil else { return }
        do {
            try saveServerAddress()
            await registerDevice()
            await loadGames()
            if account == nil {
                account = TinplateAccount(id: "", username: username, displayName: nil)
            }
            isAuthenticated = token != nil
        } catch {
            status = "会话恢复失败：\(error.localizedDescription)"
        }
    }

    func loadGames() async {
        do {
            let response: TinplateGameListResponse = try await request("games", authenticated: false)
            games = response.games
            if let selectedGameSlug, !games.contains(where: { $0.slug == selectedGameSlug }) {
                self.selectedGameSlug = nil
                UserDefaults.standard.removeObject(forKey: Self.selectedGameKey)
            }
            status = "游戏库已更新，共 \(games.count) 个游戏配置"
        } catch {
            status = "获取游戏库失败：\(error.localizedDescription)"
        }
    }

    func selectGame(_ game: TinplateGame) async {
        selectedGameSlug = game.slug
        UserDefaults.standard.set(game.slug, forKey: Self.selectedGameKey)

        if let custom = RuntimeServerSettings.savedCustomAddress(forGameSlug: game.slug) {
            _ = RuntimeServerSettings.save(loginAddress: custom)
            status = "已选择 \(game.name)，使用本机自定义服务器地址"
            return
        }

        do {
            let response: TinplateConnectionResponse = try await request(
                "games/\(game.slug)/connection", authenticated: false
            )
            let address = "\(response.defaultConnection.host):\(response.defaultConnection.port)"
            guard RuntimeServerSettings.parseLogin(address) != nil else {
                status = "已选择 \(game.name)，但默认地址不是当前游戏通信模块支持的 IPv4:端口格式，请手动设置"
                return
            }
            _ = RuntimeServerSettings.save(loginAddress: address)
            status = "已选择 \(game.name)，已应用后台默认地址 \(address)"
        } catch {
            status = "已选择 \(game.name)，读取默认连接地址失败：\(error.localizedDescription)"
        }
    }

    func useDefaultConnection() async {
        guard let game = selectedGame else {
            status = "请先选择游戏"
            return
        }
        do {
            let response: TinplateConnectionResponse = try await request(
                "games/\(game.slug)/connection", authenticated: false
            )
            let address = "\(response.defaultConnection.host):\(response.defaultConnection.port)"
            guard RuntimeServerSettings.parseLogin(address) != nil else {
                throw TinplateClientError(message: "默认地址不是当前游戏通信模块支持的 IPv4:端口格式")
            }
            UserDefaults.standard.removeObject(forKey: RuntimeServerSettings.customKey(for: game.slug))
            _ = RuntimeServerSettings.save(loginAddress: address)
            status = "已恢复 \(game.name) 的后台默认连接地址"
        } catch {
            status = "恢复默认地址失败：\(error.localizedDescription)"
        }
    }

    func saveCustomConnection(host: String, port: String) {
        guard let game = selectedGame else {
            status = "请先选择游戏"
            return
        }
        let address = "\(host.trimmingCharacters(in: .whitespacesAndNewlines)):\(port.trimmingCharacters(in: .whitespacesAndNewlines))"
        if let issue = RuntimeServerSettings.save(loginAddress: address, forGameSlug: game.slug) {
            status = issue
        } else {
            status = "已保存 \(game.name) 的自定义连接地址"
        }
    }

    private struct DevicePayload: Encodable {
        let randomDeviceId: String
        let model: String
        let osVersion: String
        let launcherVersion: String
        let ruffleVersion: String
    }

    private func registerDevice() async {
        guard token != nil else { return }
        let randomID: String
        if let existing = UserDefaults.standard.string(forKey: Self.deviceRandomIDKey) {
            randomID = existing
        } else {
            randomID = UUID().uuidString.lowercased()
            UserDefaults.standard.set(randomID, forKey: Self.deviceRandomIDKey)
        }
        let payload = DevicePayload(
            randomDeviceId: randomID,
            model: UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion,
            launcherVersion: Self.launcherVersion,
            ruffleVersion: Self.ruffleVersion
        )
        do {
            let body = try JSONEncoder().encode(payload)
            let response: TinplateDeviceResponse = try await request("devices", method: "POST", body: body)
            serverDeviceID = response.device.id
            UserDefaults.standard.set(response.device.id, forKey: "tinplate.device.serverID")
        } catch {
            status = "账号已登录，但设备登记失败：\(error.localizedDescription)"
        }
    }

    func heartbeat() async {
        guard let serverDeviceID, token != nil else { return }
        do {
            let body = try encodeBody([
                "launcherVersion": Self.launcherVersion,
                "ruffleVersion": Self.ruffleVersion,
                "lastGameId": selectedGame?.id as Any? ?? NSNull()
            ])
            struct HeartbeatResponse: Decodable { let success: Bool }
            _ = try await request(
                "devices/\(serverDeviceID)/heartbeat",
                method: "POST",
                body: body,
                as: HeartbeatResponse.self
            )
        } catch {
            LaunchDiagnostics.log("[小铁皮心跳] \(error.localizedDescription)")
        }
    }
}

// MARK: - User-facing service hub

struct TinplateHubView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: TinplateClientModel
    @State private var registerMode = false
    @State private var password = ""
    @State private var customHost = RuntimeServerSettings.configuredLogin?.host ?? ""
    @State private var customPort = RuntimeServerSettings.configuredLogin.map { String($0.port) } ?? ""
    @State private var showingRecoveryCode = false

    var body: some View {
        NavigationStack {
            Form {
                Section("小铁皮服务端") {
                    TextField("https://你的服务端域名", text: $model.serverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("保存服务端地址并刷新游戏库") {
                        do {
                            try model.saveServerAddress()
                            Task { await model.loadGames() }
                        } catch {
                            model.status = error.localizedDescription
                        }
                    }
                    Text("正式使用必须配置 HTTPS。账号密码和登录令牌不会通过普通 HTTP 发送。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if model.isAuthenticated {
                    Section("账号") {
                        LabeledContent("当前账号", value: model.account?.username ?? model.username)
                        Button("退出登录", role: .destructive) {
                            Task { await model.logout() }
                        }
                    }
                    Section("游戏库") {
                        if model.games.isEmpty {
                            Text("暂无已发布游戏，或尚未连接服务端。")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.games) { game in
                            Button {
                                Task { await model.selectGame(game) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: model.selectedGameSlug == game.slug ? "checkmark.circle.fill" : "gamecontroller")
                                        .foregroundStyle(model.selectedGameSlug == game.slug ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(game.name).foregroundStyle(.primary)
                                        if let notice = game.maintenanceNotice, !notice.isEmpty {
                                            Text(notice).font(.caption).foregroundStyle(.orange)
                                        } else if let description = game.description, !description.isEmpty {
                                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    if model.selectedGameSlug == game.slug {
                                        Text("已选择").font(.caption).foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Button("刷新游戏库") { Task { await model.loadGames() } }
                    }
                    if let game = model.selectedGame {
                        Section("游戏连接 · \(game.name)") {
                            TextField("游戏服务器 IPv4", text: $customHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.numbersAndPunctuation)
                            TextField("端口", text: $customPort)
                                .keyboardType(.numberPad)
                            Button("保存本游戏自定义地址") {
                                model.saveCustomConnection(host: customHost, port: customPort)
                            }
                            Button("恢复后台默认地址") {
                                Task {
                                    await model.useDefaultConnection()
                                    customHost = RuntimeServerSettings.configuredLogin?.host ?? ""
                                    customPort = RuntimeServerSettings.configuredLogin.map { String($0.port) } ?? ""
                                }
                            }
                            Text("当前生效：\(RuntimeServerSettings.configuredLogin?.address ?? "未设置")")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section(registerMode ? "创建免费账号" : "账号登录") {
                        TextField("用户名（3–32 位字母、数字或下划线）", text: $model.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码（至少 12 位）", text: $password)
                        Button(model.isBusy ? "请稍候…" : (registerMode ? "注册账号" : "登录")) {
                            Task {
                                if registerMode {
                                    await model.register(password: password)
                                    showingRecoveryCode = model.recoveryCode != nil
                                } else {
                                    await model.login(password: password)
                                }
                                password = ""
                            }
                        }
                        .disabled(model.isBusy || model.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                        Button(registerMode ? "已有账号？返回登录" : "没有账号？免费注册") {
                            registerMode.toggle()
                        }
                        .font(.footnote)
                    }
                }

                Section("连接状态") {
                    if model.isBusy { ProgressView() }
                    Text(model.status)
                        .font(.footnote)
                        .textSelection(.enabled)
                    if model.isAuthenticated {
                        Button("发送设备心跳") { Task { await model.heartbeat() } }
                            .font(.footnote)
                    }
                }

                Section("说明") {
                    Text("当前阶段已接入账号、设备登记、游戏库和游戏默认连接。资源服务器热更新已从此客户端基线移除。在线补丁、诊断日志和工单界面将在后续阶段接入对应接口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("小铁皮")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                await model.restoreSession()
                if model.games.isEmpty { await model.loadGames() }
            }
            .alert("请保存账号恢复码", isPresented: $showingRecoveryCode) {
                Button("我已保存", role: .cancel) { model.clearRecoveryCode() }
            } message: {
                Text(model.recoveryCode ?? "恢复码仅在注册成功时显示一次，请妥善保存。")
            }
        }
    }
}
