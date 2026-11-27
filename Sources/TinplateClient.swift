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



struct TinplateAccountEnvelope: Decodable {
    let account: TinplateAccount
}

struct TinplateAnnouncement: Codable, Identifiable {
    let id: String
    let title: String
    let content: String
    let createdAt: String
}

struct TinplateAnnouncementListResponse: Decodable {
    let announcements: [TinplateAnnouncement]
}

struct TinplateNotification: Codable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let body: String
    let targetId: String?
    let readAt: String?
    let createdAt: String
}

struct TinplateNotificationListResponse: Decodable {
    let unreadCount: Int
    let notifications: [TinplateNotification]
}

struct TinplateTicket: Codable, Identifiable {
    let id: String
    let category: String
    let title: String
    let status: String
    let gameId: String?
    let deviceId: String?
    let createdAt: String
    let updatedAt: String
}

struct TinplateTicketListResponse: Decodable {
    let tickets: [TinplateTicket]
}

struct TinplateTicketCreateResponse: Decodable {
    struct CreatedTicket: Decodable {
        let id: String
        let status: String
        let diagnosticId: String?
        let createdAt: String
    }
    let success: Bool
    let ticket: CreatedTicket
}

struct TinplateActionResponse: Decodable {
    let success: Bool?
    let message: String?
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
    static let defaultServerAddress = "http://1.13.195.4"
    static let selectedGameKey = "tinplate.selectedGame.slug.v1"
    static let deviceRandomIDKey = "tinplate.device.randomID.v1"
    static let launcherVersion = "1.0.152"
    static let ruffleVersion = "nightly-2026-11-13"

    @Published var serverAddress = "http://1.13.195.4"
    @Published var username = UserDefaults.standard.string(forKey: "tinplate.account.username") ?? ""
    @Published var games: [TinplateGame] = []
    @Published var announcements: [TinplateAnnouncement] = []
    @Published var notifications: [TinplateNotification] = []
    @Published var unreadNotificationCount = 0
    @Published var tickets: [TinplateTicket] = []
    @Published var authError: String?
    @Published var authNotice: String?
    @Published var selectedGameSlug = UserDefaults.standard.string(forKey: selectedGameKey)
    @Published private(set) var account: TinplateAccount?
    @Published private(set) var isAuthenticated = false
    @Published var isBusy = false
    @Published var status = "已连接小铁皮服务端配置"
    @Published private(set) var recoveryCode: String?
    @Published private(set) var serverDeviceID: String?

    private var token: String?
    private let session: URLSession

    init() {
        let tokenBase = UserDefaults.standard.string(forKey: "tinplate.token.serverAddress") ?? ""
        if tokenBase != Self.defaultServerAddress {
            TinplateTokenVault.delete()
            UserDefaults.standard.removeObject(forKey: "tinplate.token.serverAddress")
        }
        UserDefaults.standard.set(Self.defaultServerAddress, forKey: Self.baseURLKey)
        serverAddress = Self.defaultServerAddress
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
        guard let components = URLComponents(string: Self.defaultServerAddress),
              components.scheme?.lowercased() == "http",
              components.host == "1.13.195.4",
              components.port == nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url else {
            throw TinplateClientError(message: "内置小铁皮服务端地址无效")
        }
        return url
    }

    func saveServerAddress() throws {
        _ = try validatedBaseURL()
        serverAddress = Self.defaultServerAddress
        UserDefaults.standard.set(Self.defaultServerAddress, forKey: Self.baseURLKey)
        status = "已使用内置小铁皮服务端"
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
                account = nil
                isAuthenticated = false
                serverDeviceID = nil
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
        authError = nil
        authNotice = nil
        status = "已登录：\(account?.username ?? username)"
        await registerDevice()
        await loadGames()
        await loadAnnouncements()
        await loadNotifications()
    }

    func clearRecoveryCode() { recoveryCode = nil }

    func register(password: String) async {
        guard !isBusy else { return }
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3, normalized.count <= 32,
              normalized.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
            authError = "用户名需为 3–32 位字母、数字或下划线。"
            return
        }
        guard password.count >= 6, password.count <= 128 else {
            authError = "密码至少 6 位，最多 128 位。"
            return
        }
        isBusy = true
        authError = nil
        authNotice = nil
        defer { isBusy = false }
        do {
            try saveServerAddress()
            username = normalized
            let body = try encodeBody(["username": normalized, "password": password])
            let response: TinplateAuthResponse = try await request(
                "account/register", method: "POST", body: body, authenticated: false
            )
            await applyAuthentication(response)
            if recoveryCode != nil {
                status = "注册成功，请立即保存一次性恢复码"
                authNotice = "账号注册成功。请妥善保存一次性恢复码，关闭后无法再次查看。"
            }
        } catch {
            authError = error.localizedDescription
            status = "注册失败：\(error.localizedDescription)"
        }
    }

    func login(password: String) async {
        guard !isBusy else { return }
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, password.count >= 6, password.count <= 128 else {
            authError = "请输入账号和至少 6 位密码。"
            return
        }
        isBusy = true
        authError = nil
        authNotice = nil
        defer { isBusy = false }
        do {
            try saveServerAddress()
            username = normalized
            let body = try encodeBody(["username": normalized, "password": password])
            let response: TinplateAuthResponse = try await request(
                "account/login", method: "POST", body: body, authenticated: false
            )
            await applyAuthentication(response)
        } catch {
            authError = error.localizedDescription
            status = "登录失败：\(error.localizedDescription)"
        }
    }

    func recoverPassword(username recoveryUsername: String, recoveryCode: String, newPassword: String) async -> Bool {
        guard !isBusy else { return false }
        guard newPassword.count >= 6, newPassword.count <= 128 else {
            authError = "新密码至少 6 位，最多 128 位。"
            return false
        }
        isBusy = true
        authError = nil
        authNotice = nil
        defer { isBusy = false }
        do {
            try saveServerAddress()
            let body = try encodeBody([
                "username": recoveryUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                "recoveryCode": recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines),
                "newPassword": newPassword
            ])
            let response: TinplateActionResponse = try await request(
                "account/recover-password", method: "POST", body: body, authenticated: false
            )
            authNotice = response.message ?? "密码已重置，请使用新密码登录。"
            status = authNotice ?? "密码已重置"
            return true
        } catch {
            authError = error.localizedDescription
            return false
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
        guard token != nil else {
            isAuthenticated = false
            return
        }
        do {
            try saveServerAddress()
            let response: TinplateAccountEnvelope = try await request("account/me")
            account = response.account
            username = response.account.username
            isAuthenticated = true
            await registerDevice()
            await loadGames()
            await loadAnnouncements()
            await loadNotifications()
        } catch {
            status = "会话恢复失败：\(error.localizedDescription)"
            if token == nil { isAuthenticated = false }
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
            if self.selectedGameSlug == nil, let first = games.first {
                self.selectedGameSlug = first.slug
                UserDefaults.standard.set(first.slug, forKey: Self.selectedGameKey)
            }
            if let selected = selectedGame { await selectGame(selected) }
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

    func loadAnnouncements() async {
        guard !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let response: TinplateAnnouncementListResponse = try await request(
                "announcements", authenticated: false
            )
            announcements = response.announcements
        } catch {
            LaunchDiagnostics.log("[小铁皮公告] \(error.localizedDescription)")
        }
    }

    func loadNotifications() async {
        guard isAuthenticated else { return }
        do {
            let response: TinplateNotificationListResponse = try await request("notifications")
            notifications = response.notifications
            unreadNotificationCount = response.unreadCount
        } catch {
            LaunchDiagnostics.log("[小铁皮通知] \(error.localizedDescription)")
        }
    }

    func loadTickets() async {
        guard isAuthenticated else { return }
        do {
            let response: TinplateTicketListResponse = try await request("tickets")
            tickets = response.tickets
        } catch {
            status = "读取工单失败：\(error.localizedDescription)"
        }
    }

    func createTicket(category: String, title: String, description: String) async -> String? {
        guard isAuthenticated else { return "请先登录小铁皮账号。" }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanTitle.count >= 3, cleanTitle.count <= 120,
              cleanDescription.count >= 10, cleanDescription.count <= 5000 else {
            return "标题需为 3–120 字，问题描述需为 10–5000 字。"
        }
        var payload: [String: Any] = [
            "category": category,
            "title": cleanTitle,
            "description": cleanDescription
        ]
        if let serverDeviceID { payload["deviceId"] = serverDeviceID }
        if let selectedGame { payload["gameId"] = selectedGame.id }
        do {
            let body = try encodeBody(payload)
            let _: TinplateTicketCreateResponse = try await request(
                "tickets", method: "POST", body: body
            )
            await loadTickets()
            return nil
        } catch {
            return error.localizedDescription
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
                    LabeledContent("内置 API 地址", value: TinplateClientModel.defaultServerAddress)
                    Text("服务端地址已内置，普通用户无需配置。")
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
                        SecureField("密码（至少 6 位）", text: $password)
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


// MARK: - New Tinplate launcher shell (B150 runtime remains unchanged)

extension Notification.Name {
    static let tinplateGameClosed = Notification.Name("cn.qimeng321.tinplate.gameClosed")
}

enum TinplateTab: String, CaseIterable, Identifiable {
    case home, patches, tickets, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "首页"
        case .patches: return "补丁"
        case .tickets: return "工单"
        case .profile: return "我的"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .patches: return "puzzlepiece.fill"
        case .tickets: return "doc.text.fill"
        case .profile: return "person.fill"
        }
    }
}

struct TinplateRootView: View {
    @EnvironmentObject private var launcher: LauncherModel
    @EnvironmentObject private var model: TinplateClientModel
    @State private var showingLegacyLauncher = false
    @State private var autoLaunchGame = false
    @State private var selectedTab: TinplateTab = .home

    var body: some View {
        Group {
            if model.isAuthenticated {
                TinplateDashboardView(
                    selectedTab: $selectedTab,
                    onEnterGame: openGame,
                    onGameSettings: openGameSettings
                )
            } else {
                TinplateLoginView()
            }
        }
        .background(Color.white.ignoresSafeArea())
        .fullScreenCover(isPresented: $showingLegacyLauncher, onDismiss: {
            autoLaunchGame = false
        }) {
            ZStack(alignment: .topLeading) {
                LauncherView(autoLaunchOnAppear: autoLaunchGame)
                    .environmentObject(launcher)
                    .environmentObject(model)
                Button {
                    showingLegacyLauncher = false
                } label: {
                    Label("返回首页", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0.12, green: 0.35, blue: 0.78))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(Color.white.opacity(0.94), in: Capsule())
                        .overlay(Capsule().stroke(Color.blue.opacity(0.14), lineWidth: 1))
                }
                .padding(.top, 7)
                .padding(.leading, 14)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tinplateGameClosed)) { _ in
            showingLegacyLauncher = false
        }
        .alert("请保存注册恢复码", isPresented: Binding(
            get: { model.recoveryCode != nil },
            set: { if !$0 { model.clearRecoveryCode() } }
        )) {
            Button("我已保存", role: .cancel) { model.clearRecoveryCode() }
        } message: {
            Text(model.recoveryCode ?? "恢复码仅在注册成功时显示一次，请妥善保存。")
        }
        .task {
            await model.restoreSession()
            if !model.serverAddress.isEmpty { await model.loadAnnouncements() }
            if model.isAuthenticated { await model.loadNotifications() }
        }
    }

    private func openGame() {
        autoLaunchGame = true
        showingLegacyLauncher = true
    }

    private func openGameSettings() {
        autoLaunchGame = false
        showingLegacyLauncher = true
    }
}

struct TinplateLoginView: View {
    @EnvironmentObject private var model: TinplateClientModel
    @State private var registerMode = false
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var showingRecovery = false

    private let ink = Color(red: 0.08, green: 0.15, blue: 0.32)
    private let muted = Color(red: 0.40, green: 0.48, blue: 0.64)
    private let blue = Color(red: 0.06, green: 0.43, blue: 0.98)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    Image("LauncherArt")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: blue.opacity(0.18), radius: 20, y: 8)
                    Text("小铁皮启动器")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(ink)
                        .padding(.top, 16)
                    Text("经典游戏 · 自由畅玩")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(muted)
                        .padding(.top, 8)

                    VStack(spacing: 14) {
                        inputField(icon: "person.fill") {
                            TextField("请输入账号", text: $model.username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.asciiCapable)
                        }

                        HStack(spacing: 11) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(muted)
                                .frame(width: 24)
                            Group {
                                if showPassword {
                                    TextField("请输入密码", text: $password)
                                } else {
                                    SecureField("请输入密码", text: $password)
                                }
                            }
                            .textContentType(registerMode ? .newPassword : .password)
                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye" : "eye.slash")
                                    .foregroundColor(muted)
                            }
                        }
                        .padding(.horizontal, 17)
                        .frame(height: 58)
                        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.12), lineWidth: 1))

                        if registerMode {
                            inputField(icon: "lock.shield.fill") {
                                SecureField("请再次输入密码", text: $confirmPassword)
                                    .textContentType(.newPassword)
                            }
                        }

                        HStack {
                            Spacer()
                            if !registerMode {
                                Button("忘记密码？") { showingRecovery = true }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(blue)
                            } else {
                                Text("密码至少 6 位")
                                    .font(.system(size: 13))
                                    .foregroundColor(muted)
                            }
                        }

                        if let error = model.authError, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let notice = model.authNotice, !notice.isEmpty, model.recoveryCode == nil {
                            Text(notice)
                                .font(.system(size: 13))
                                .foregroundColor(Color.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button(action: submit) {
                            HStack(spacing: 8) {
                                if model.isBusy { ProgressView().tint(.white) }
                                Text(model.isBusy ? "请稍候…" : (registerMode ? "注册新账号" : "登录"))
                                    .font(.system(size: 19, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 60)
                            .foregroundColor(.white)
                            .background(
                                LinearGradient(colors: [Color(red: 0.03, green: 0.58, blue: 0.99), blue],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                        }
                        .disabled(model.isBusy)
                        .buttonStyle(.plain)

                        Button {
                            registerMode.toggle()
                            password = ""
                            confirmPassword = ""
                            model.authError = nil
                            model.authNotice = nil
                        } label: {
                            Text(registerMode ? "已有账号？返回登录" : "注册新账号")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 58)
                                .foregroundColor(blue)
                                .background(Color.white.opacity(0.72), in: Capsule())
                                .overlay(Capsule().stroke(blue, lineWidth: 1.3))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 34)
                    .frame(maxWidth: 470)

                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .background(
                LinearGradient(colors: [
                    Color(red: 0.97, green: 0.98, blue: 1.0),
                    Color.white,
                    Color(red: 0.91, green: 0.95, blue: 1.0)
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            )
        }
        .sheet(isPresented: $showingRecovery) {
            TinplateRecoveryView()
        }
    }

    private func inputField<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(muted)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 17)
        .frame(height: 58)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.12), lineWidth: 1))
    }

    private func submit() {
        model.authError = nil
        if registerMode && password != confirmPassword {
            model.authError = "两次输入的密码不一致。"
            return
        }
        Task {
            if registerMode {
                await model.register(password: password)
            } else {
                await model.login(password: password)
            }
        }
    }
}

struct TinplateRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: TinplateClientModel
    @State private var username = ""
    @State private var recoveryCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var completed = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("一次性恢复码", text: $recoveryCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("设置新密码") {
                    SecureField("新密码（至少 6 位）", text: $newPassword)
                    SecureField("确认新密码", text: $confirmPassword)
                }
                if let error = model.authError {
                    Section { Text(error).foregroundColor(.red) }
                }
                Button("重置密码") {
                    guard newPassword == confirmPassword else {
                        model.authError = "两次输入的密码不一致。"
                        return
                    }
                    Task {
                        completed = await model.recoverPassword(
                            username: username,
                            recoveryCode: recoveryCode,
                            newPassword: newPassword
                        )
                    }
                }
                .disabled(model.isBusy)
            }
            .navigationTitle("找回密码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .alert("密码已重置", isPresented: $completed) {
                Button("返回登录") { dismiss() }
            } message: {
                Text(model.authNotice ?? "请使用新密码登录。")
            }
        }
    }
}

struct TinplateDashboardView: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Binding var selectedTab: TinplateTab
    let onEnterGame: () -> Void
    let onGameSettings: () -> Void
    @State private var showingNotifications = false
    @State private var showingAnnouncements = false

    private let ink = Color(red: 0.08, green: 0.14, blue: 0.30)
    private let muted = Color(red: 0.40, green: 0.47, blue: 0.62)
    private let blue = Color(red: 0.05, green: 0.43, blue: 0.98)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                Group {
                    switch selectedTab {
                    case .home: homePage
                    case .patches: patchesPage
                    case .tickets: TinplateTicketsPage()
                    case .profile: profilePage
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 18)
            }
            bottomBar
        }
        .background(Color(red: 0.97, green: 0.98, blue: 1.0).ignoresSafeArea())
        .sheet(isPresented: $showingNotifications) {
            TinplateNotificationsView()
        }
        .sheet(isPresented: $showingAnnouncements) {
            TinplateAnnouncementsView()
        }
        .onChange(of: selectedTab) { next in
            if next == .tickets { Task { await model.loadTickets() } }
        }
        .task {
            if model.announcements.isEmpty { await model.loadAnnouncements() }
            if model.isAuthenticated { await model.loadNotifications() }
        }
    }

    private var greetingName: String {
        guard let name = model.account?.displayName, !name.isEmpty else { return "小铁皮" }
        return name
    }

    private var profileName: String {
        guard let name = model.account?.displayName, !name.isEmpty else { return model.username }
        return name
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 11) {
                Image("LauncherArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.blue.opacity(0.12), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("你好，\(greetingName)")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ink)
                    Text("UID: \(model.account?.id ?? model.username)")
                        .font(.system(size: 12))
                        .foregroundColor(muted)
                        .lineLimit(1)
                }
                Spacer()
                Button { showingNotifications = true } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(muted)
                            .frame(width: 42, height: 42)
                        if model.unreadNotificationCount > 0 {
                            Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: -4, y: 4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("消息通知")
            }

            banner

            gameCard

            gameLibrary

            announcementsPanel
        }
    }

    private var banner: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [
                Color(red: 0.06, green: 0.30, blue: 0.76),
                Color(red: 0.12, green: 0.48, blue: 0.96),
                Color(red: 0.48, green: 0.42, blue: 0.88)
            ], startPoint: .leading, endPoint: .trailing)
            Circle().fill(Color.white.opacity(0.08)).frame(width: 190, height: 190).offset(x: 205, y: -55)
            Circle().fill(Color.white.opacity(0.08)).frame(width: 120, height: 120).offset(x: 270, y: 50)
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.selectedGame?.name ?? "小铁皮游戏库")
                        .font(.system(size: 25, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("经典回归 · 再次启航")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                Spacer(minLength: 4)
                Image("LauncherArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
            }
            .padding(.horizontal, 19)
        }
        .frame(height: 145)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var gameCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image("LauncherArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedGame?.name ?? "请选择游戏")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ink)
                    Text("游戏服务器：\(RuntimeServerSettings.configuredLogin?.address ?? "未设置")")
                        .font(.system(size: 12))
                        .foregroundColor(muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(muted)
            }
            HStack(spacing: 10) {
                Button(action: onEnterGame) {
                    Label("进入游戏", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .foregroundColor(.white)
                        .background(LinearGradient(colors: [Color(red: 0.04, green: 0.60, blue: 0.99), blue],
                                                   startPoint: .leading, endPoint: .trailing), in: Capsule())
                }
                .disabled(model.selectedGame == nil)
                .buttonStyle(.plain)

                Button(action: onGameSettings) {
                    Label("游戏设置", systemImage: "gearshape.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .foregroundColor(blue)
                        .background(Color.white, in: Capsule())
                        .overlay(Capsule().stroke(blue.opacity(0.32), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(15)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color.blue.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.blue.opacity(0.035), radius: 10, y: 4)
    }

    private var gameLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("我的游戏库")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(ink)
                Spacer()
                Text("共 \(model.games.count) 款游戏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(muted)
                Button { Task { await model.loadGames() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(blue)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(model.games) { game in
                        let selected = model.selectedGameSlug == game.slug
                        Button {
                            Task { await model.selectGame(game) }
                        } label: {
                            VStack(spacing: 5) {
                                Image("LauncherArt")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 55, height: 55)
                                    .padding(5)
                                    .background(Color(red: 0.93, green: 0.96, blue: 1), in: RoundedRectangle(cornerRadius: 14))
                                Text(game.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(ink)
                                    .lineLimit(1)
                            }
                            .frame(width: 88, height: 106)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? blue : Color.blue.opacity(0.08), lineWidth: selected ? 2 : 1))
                            .shadow(color: selected ? blue.opacity(0.10) : .clear, radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { Task { await model.loadGames() } } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 27, weight: .medium))
                                .foregroundColor(muted)
                            Text("添加游戏")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(ink)
                        }
                        .frame(width: 88, height: 106)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.blue.opacity(0.08), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var announcementsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最新公告", systemImage: "megaphone.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ink)
                Spacer()
                Button("更多  ›") { showingAnnouncements = true }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(muted)
            }
            if model.announcements.isEmpty {
                Text("暂无公告")
                    .font(.system(size: 13))
                    .foregroundColor(muted)
                    .padding(.vertical, 7)
            } else {
                ForEach(Array(model.announcements.prefix(3))) { item in
                    HStack(spacing: 8) {
                        Circle().fill(blue.opacity(0.78)).frame(width: 5, height: 5)
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(item.createdAt.prefix(10)))
                            .font(.system(size: 11))
                            .foregroundColor(muted)
                    }
                }
            }
        }
        .padding(15)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder private var patchesPage: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("补丁中心")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(ink)
            VStack(alignment: .leading, spacing: 10) {
                Label("在线补丁", systemImage: "puzzlepiece.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(ink)
                Text("服务端补丁发布接口已预留。当前客户端尚未完成签名公钥固定、文件验签和安全安装流程，因此不会下载或执行未验证的补丁。")
                    .font(.system(size: 14))
                    .foregroundColor(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    @ViewBuilder private var profilePage: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("我的")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(ink)
            HStack(spacing: 12) {
                Image("LauncherArt").resizable().scaledToFit().frame(width: 58, height: 58).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileName)
                        .font(.system(size: 18, weight: .bold)).foregroundColor(ink)
                    Text("UID: \(model.account?.id ?? model.username)")
                        .font(.system(size: 12)).foregroundColor(muted).lineLimit(1)
                }
                Spacer()
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 0) {
                profileRow("当前游戏", value: model.selectedGame?.name ?? "未选择")
                Divider()
                profileRow("游戏服务器", value: RuntimeServerSettings.configuredLogin?.address ?? "未设置")
            }
            .padding(15)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
            Button(action: onGameSettings) {
                Label("游戏设置与资源导入", systemImage: "gearshape.fill")
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundColor(blue)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            Button {
                Task { await model.logout() }
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .foregroundColor(.red)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private func profileRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundColor(muted)
            Spacer(minLength: 8)
            Text(value.isEmpty ? "未设置" : value)
                .foregroundColor(ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.system(size: 13))
        .padding(.vertical, 9)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(TinplateTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 21, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(selectedTab == tab ? blue : muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(selectedTab == tab ? Color.blue.opacity(0.07) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .background(Color.white.shadow(color: Color.black.opacity(0.04), radius: 8, y: -3))
    }
}

struct TinplateNotificationsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: TinplateClientModel

    var body: some View {
        NavigationStack {
            List {
                if model.notifications.isEmpty {
                    Text("暂无通知").foregroundColor(.secondary)
                } else {
                    ForEach(model.notifications) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.title).font(.headline)
                                Spacer()
                                if item.readAt == nil {
                                    Circle().fill(Color.red).frame(width: 7, height: 7)
                                }
                            }
                            Text(item.body).font(.subheadline).foregroundColor(.secondary)
                            Text(String(item.createdAt.prefix(16))).font(.caption).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("消息通知")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await model.loadNotifications() }
    }
}

struct TinplateAnnouncementsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: TinplateClientModel

    var body: some View {
        NavigationStack {
            List(model.announcements) { item in
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title).font(.headline)
                    Text(item.content).font(.subheadline).foregroundColor(.secondary)
                    Text(String(item.createdAt.prefix(16))).font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
            }
            .navigationTitle("全部公告")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task { await model.loadAnnouncements() }
    }
}

struct TinplateTicketsPage: View {
    @EnvironmentObject private var model: TinplateClientModel
    @State private var showingComposer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("工单中心").font(.system(size: 24, weight: .bold))
                Spacer()
                Button {
                    showingComposer = true
                } label: {
                    Label("新建工单", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            }
            if model.tickets.isEmpty {
                Text("暂无工单。遇到登录、崩溃、导入或游戏问题时，可以在这里提交反馈。")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            } else {
                ForEach(model.tickets) { ticket in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ticket.title).font(.system(size: 15, weight: .semibold))
                        HStack {
                            Text(ticket.category)
                            Spacer()
                            Text(ticket.status)
                            Text(String(ticket.createdAt.prefix(10)))
                        }
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15))
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            TinplateTicketComposer()
        }
        .task { await model.loadTickets() }
    }
}

struct TinplateTicketComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: TinplateClientModel
    @State private var category = "OTHER"
    @State private var title = ""
    @State private var description = ""
    @State private var sending = false
    @State private var errorMessage: String?

    private let categories: [(String, String)] = [
        ("LOGIN", "登录问题"), ("CRASH", "闪退问题"), ("IMPORT", "资源导入"),
        ("PERFORMANCE", "运行性能"), ("PATCH", "补丁问题"),
        ("OPERATION", "操作问题"), ("SUGGESTION", "功能建议"), ("OTHER", "其他")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("问题分类") {
                    Picker("分类", selection: $category) {
                        Text("登录问题").tag("LOGIN")
                        Text("闪退问题").tag("CRASH")
                        Text("资源导入").tag("IMPORT")
                        Text("运行性能").tag("PERFORMANCE")
                        Text("补丁问题").tag("PATCH")
                        Text("操作问题").tag("OPERATION")
                        Text("功能建议").tag("SUGGESTION")
                        Text("其他").tag("OTHER")
                    }
                }
                Section("工单内容") {
                    TextField("标题（至少 3 个字）", text: $title)
                    TextEditor(text: $description).frame(minHeight: 150)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red) }
                }
                Button(sending ? "正在提交…" : "提交工单") {
                    sending = true
                    Task {
                        let error = await model.createTicket(category: category, title: title, description: description)
                        sending = false
                        if let error { errorMessage = error } else { dismiss() }
                    }
                }
                .disabled(sending)
            }
            .navigationTitle("新建工单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
