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



struct TinplateMeResponse: Decodable { let account: TinplateAccount }

struct TinplateCategory: Codable, Hashable { let name: String }

struct TinplateAnnouncement: Codable, Identifiable {
    let id: String
    let title: String
    let content: String
    let createdAt: String
    let updatedAt: String?
    let categories: [TinplateCategory]?
    let tags: [TinplateCategory]?
}

struct TinplateAnnouncementListResponse: Decodable {
    let success: Bool
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
    let success: Bool
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
    let diagnosticId: String?
    let createdAt: String
    let updatedAt: String
}

struct TinplateTicketListResponse: Decodable {
    let success: Bool
    let tickets: [TinplateTicket]
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
    // Set this to the production HTTPS origin after TLS is enabled on the service.
    static let builtInServerAddress = ""
    static let selectedGameKey = "tinplate.selectedGame.slug.v1"
    static let deviceRandomIDKey = "tinplate.device.randomID.v1"
    static let launcherVersion = "1.0.153"
    static let ruffleVersion = "R6-Air2-B142"

    @Published var serverAddress = UserDefaults.standard.string(forKey: baseURLKey) ?? TinplateClientModel.builtInServerAddress
    @Published var username = UserDefaults.standard.string(forKey: "tinplate.account.username") ?? ""
    @Published var games: [TinplateGame] = []
    @Published var announcements: [TinplateAnnouncement] = []
    @Published var notifications: [TinplateNotification] = []
    @Published var tickets: [TinplateTicket] = []
    @Published var unreadCount = 0
    @Published var selectedGameSlug = UserDefaults.standard.string(forKey: selectedGameKey)
    @Published private(set) var account: TinplateAccount?
    @Published private(set) var isAuthenticated = false
    @Published var isBusy = false
    @Published var status = "请先配置小铁皮服务端 HTTPS 地址"
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
        serverDeviceID = UserDefaults.standard.string(forKey: "tinplate.device.serverID")
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
            UserDefaults.standard.removeObject(forKey: "tinplate.device.serverID")
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

        let (data, response) = try await session.compatData(for: request)
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
        await loadAnnouncements()
        await loadNotifications()
        await loadTickets()
    }

    func clearRecoveryCode() { recoveryCode = nil }

    func register(password: String) async {
        guard !isBusy else { return }
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: "^[A-Za-z0-9_]{3,32}$", options: .regularExpression) != nil else {
            status = "注册失败：用户名须为 3–32 位字母、数字或下划线"
            return
        }
        guard (12...128).contains(password.count) else {
            status = "注册失败：密码长度须为 12–128 位"
            return
        }
        username = normalized
        isBusy = true
        defer { isBusy = false }
        do {
            try saveServerAddress()
            let body = try encodeBody(["username": normalized, "password": password])
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
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 32, !password.isEmpty, password.count <= 128 else {
            status = "登录失败：请检查用户名和密码"
            return
        }
        username = normalized
        isBusy = true
        defer { isBusy = false }
        do {
            try saveServerAddress()
            let body = try encodeBody(["username": normalized, "password": password])
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
        UserDefaults.standard.removeObject(forKey: "tinplate.device.serverID")
        TinplateTokenVault.delete()
        UserDefaults.standard.removeObject(forKey: "tinplate.token.serverAddress")
        status = "已退出小铁皮账号"
    }

    func restoreSession() async {
        guard token != nil else { return }
        do {
            try saveServerAddress()
            let me: TinplateMeResponse = try await request("account/me")
            account = me.account
            await registerDevice()
            await loadGames()
            await loadAnnouncements()
            await loadNotifications()
            await loadTickets()
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
            if selectedGameSlug == nil, let first = games.first {
                await selectGame(first)
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


    func loadAnnouncements() async {
        do {
            let response: TinplateAnnouncementListResponse = try await request("announcements", authenticated: false)
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
            unreadCount = response.unreadCount
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
            LaunchDiagnostics.log("[小铁皮工单] \(error.localizedDescription)")
        }
    }

    func markNotificationsRead() async {
        struct MarkReadResponse: Decodable { let success: Bool; let markedRead: Int? }
        do {
            _ = try await request("notifications", method: "POST", body: try encodeBody([:]), as: MarkReadResponse.self)
            await loadNotifications()
        } catch {
            status = "标记通知失败：\(error.localizedDescription)"
        }
    }

    func recoverPassword(username: String, recoveryCode: String, newPassword: String) async {
        guard !isBusy else { return }
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(of: "^[A-Za-z0-9_]{3,32}$", options: .regularExpression) != nil,
              recoveryCode.count == 43, (12...128).contains(newPassword.count) else {
            status = "找回失败：请检查用户名、43 位恢复码和新密码长度"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let body = try encodeBody([
                "username": normalized,
                "recoveryCode": recoveryCode,
                "newPassword": newPassword
            ])
            struct RecoverResponse: Decodable { let success: Bool; let message: String? }
            let response: RecoverResponse = try await request(
                "account/recover-password", method: "POST", body: body,
                authenticated: false, as: RecoverResponse.self
            )
            status = response.message ?? (response.success ? "密码已重置，请重新登录" : "密码找回失败")
        } catch {
            status = "找回失败：\(error.localizedDescription)"
        }
    }

    func createTicket(category: String, title: String, description: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var payload: [String: Any] = [
                "category": category,
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines),
                "description": description.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            if let serverDeviceID { payload["deviceId"] = serverDeviceID }
            if let game = selectedGame { payload["gameId"] = game.id }
            let body = try encodeBody(payload)
            struct CreateResponse: Decodable { let success: Bool }
            _ = try await request("tickets", method: "POST", body: body, as: CreateResponse.self)
            status = "工单已提交"
            await loadTickets()
        } catch {
            status = "工单提交失败：\(error.localizedDescription)"
        }
    }

    func submitAdaptationApplication(gameName: String, description: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let body = try encodeBody(["gameName": gameName, "description": description])
            struct SubmitResponse: Decodable { let success: Bool }
            _ = try await request("adaptation-applications", method: "POST", body: body, as: SubmitResponse.self)
            status = "游戏适配申请已提交"
        } catch {
            status = "提交申请失败：\(error.localizedDescription)"
        }
    }

    func changeDisplayName(_ name: String) async {
        do {
            let body = try encodeBody(["displayName": name.isEmpty ? NSNull() : name as Any])
            struct UpdateResponse: Decodable { let success: Bool; let account: TinplateAccount }
            let response: UpdateResponse = try await request("account/me", method: "PATCH", body: body)
            account = response.account
            status = "昵称已更新"
        } catch {
            status = "修改昵称失败：\(error.localizedDescription)"
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



// MARK: - Tinplate app shell

struct TinplateAppRootView: View {
    @EnvironmentObject private var model: TinplateClientModel
    @State private var showingRecoveryCode = false

    var body: some View {
        Group {
            if model.isAuthenticated {
                TinplateHomeView()
            } else {
                TinplateLoginView()
            }
        }
        .onAppear {
            if model.isAuthenticated {
                Task { await model.restoreSession() }
            } else if !model.serverAddress.isEmpty {
                Task { await model.loadAnnouncements() }
            }
        }
        .onChange(of: model.recoveryCode) { value in
            showingRecoveryCode = value != nil
        }
        .sheet(isPresented: $showingRecoveryCode, onDismiss: {
            model.clearRecoveryCode()
        }) {
            TinplateRecoveryCodeSheet(code: model.recoveryCode ?? "")
        }
    }
}

private enum TinplateLoginSheet: String, Identifiable {
    case service, recovery
    var id: String { rawValue }
}

struct TinplateLoginView: View {
    @EnvironmentObject private var model: TinplateClientModel
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var registerMode = false
    @State private var revealPassword = false
    @State private var activeSheet: TinplateLoginSheet?

    private let blue = Color(red: 0.08, green: 0.40, blue: 0.98)
    private let ink = Color(red: 0.08, green: 0.15, blue: 0.31)
    private let muted = Color(red: 0.39, green: 0.47, blue: 0.64)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button(action: { activeSheet = .service }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundColor(muted)
                                .frame(width: 42, height: 42)
                                .background(Color.white.opacity(0.82))
                                .clipShape(Circle())
                        }
                        .accessibilityLabel("服务端设置")
                    }
                    .padding(.top, 8)

                    Spacer(minLength: 24)

                    Image("LauncherArt")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: blue.opacity(0.16), radius: 20, y: 9)

                    Text("小铁皮启动器")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(ink)
                        .padding(.top, 17)

                    Text("经典游戏 · 自由畅玩")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(muted)
                        .padding(.top, 8)

                    VStack(spacing: 13) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.fill")
                                .foregroundColor(muted)
                                .frame(width: 20)
                            TextField("请输入账号或用户名", text: $model.username)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .textContentType(.username)
                                .font(.system(size: 16))
                        }
                        .padding(.horizontal, 17)
                        .frame(height: 58)
                        .background(Color(red: 0.95, green: 0.97, blue: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(blue.opacity(0.11), lineWidth: 1))

                        HStack(spacing: 12) {
                            Image(systemName: "lock.fill")
                                .foregroundColor(muted)
                                .frame(width: 20)
                            Group {
                                if revealPassword {
                                    TextField("请输入密码", text: $password)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                } else {
                                    SecureField("请输入密码", text: $password)
                                }
                            }
                            .textContentType(registerMode ? .newPassword : .password)
                            .font(.system(size: 16))
                            Button(action: { revealPassword.toggle() }) {
                                Image(systemName: revealPassword ? "eye" : "eye.slash")
                                    .foregroundColor(muted)
                            }
                        }
                        .padding(.horizontal, 17)
                        .frame(height: 58)
                        .background(Color(red: 0.95, green: 0.97, blue: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(blue.opacity(0.11), lineWidth: 1))

                        if registerMode {
                            SecureField("请再次输入密码", text: $confirmPassword)
                                .font(.system(size: 16))
                                .padding(.horizontal, 17)
                                .frame(height: 58)
                                .background(Color(red: 0.95, green: 0.97, blue: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 17).stroke(blue.opacity(0.11), lineWidth: 1))
                        } else {
                            HStack {
                                Spacer()
                                Button("忘记密码？") { activeSheet = .recovery }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(blue)
                            }
                            .padding(.top, 3)
                        }
                    }
                    .padding(.top, 34)

                    Button(action: submit) {
                        HStack(spacing: 9) {
                            if model.isBusy { ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)) }
                            Text(model.isBusy ? "请稍候…" : (registerMode ? "创建账号" : "登录"))
                                .font(.system(size: 18, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(LinearGradient(
                            gradient: Gradient(colors: [Color(red: 0.04, green: 0.59, blue: 1), blue]),
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .clipShape(Capsule())
                        .shadow(color: blue.opacity(0.19), radius: 12, y: 6)
                    }
                    .disabled(model.isBusy || model.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                    .padding(.top, 27)

                    Button(action: {
                        registerMode.toggle()
                        password = ""
                        confirmPassword = ""
                        model.status = registerMode ? "注册密码至少 12 位" : "请输入账号密码"
                    }) {
                        Text(registerMode ? "已有账号？返回登录" : "注册新账号")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 58)
                            .overlay(Capsule().stroke(blue, lineWidth: 1.4))
                    }
                    .padding(.top, 17)

                    if model.serverAddress.isEmpty {
                        Button("配置小铁皮服务端") { activeSheet = .service }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(muted)
                            .padding(.top, 20)
                    }

                    if model.status.contains("失败") || model.status.contains("错误") || model.status.contains("配置") {
                        Text(model.status)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(model.status.contains("失败") || model.status.contains("错误") ? .red : muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .padding(.top, 15)
                    }

                    if registerMode {
                        Text("用户名 3–32 位；密码 12–128 位。注册成功后会显示一次性恢复码，请妥善保存。")
                            .font(.system(size: 11))
                            .foregroundColor(muted)
                            .multilineTextAlignment(.center)
                            .padding(.top, 15)
                    }

                    Spacer(minLength: 48)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white,
                        Color(red: 0.97, green: 0.98, blue: 1),
                        Color(red: 0.88, green: 0.93, blue: 1)
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .edgesIgnoringSafeArea(.all)
            )
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .service:
                TinplateServiceSettingsSheet()
            case .recovery:
                TinplateRecoveryPasswordSheet()
            }
        }
    }

    private func submit() {
        if registerMode {
            guard password == confirmPassword else {
                model.status = "注册失败：两次输入的密码不一致"
                return
            }
            Task { await model.register(password: password) }
        } else {
            Task { await model.login(password: password) }
        }
    }
}

private enum TinplateHomeSheet: String, Identifiable {
    case gameSettings, packagePicker, patchPicker, ticketComposer
    case notificationCenter, announcements, adaptationRequest, serviceSettings
    var id: String { rawValue }
}

struct TinplateHomeView: View {
    @EnvironmentObject private var model: TinplateClientModel
    @EnvironmentObject private var launcher: LauncherModel
    @State private var selectedTab = 0
    @State private var activeSheet: TinplateHomeSheet?
    @State private var showingGame = false

    private let blue = Color(red: 0.06, green: 0.42, blue: 0.98)
    private let ink = Color(red: 0.07, green: 0.13, blue: 0.29)
    private let muted = Color(red: 0.39, green: 0.46, blue: 0.62)
    private let pale = Color(red: 0.95, green: 0.97, blue: 1)

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case 0: homeContent
                case 1: patchContent
                case 2: ticketsContent
                default: profileContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .background(Color(red: 0.975, green: 0.982, blue: 0.995).edgesIgnoringSafeArea(.all))
        .onAppear {
            Task {
                await model.loadGames()
                await model.loadAnnouncements()
                await model.loadNotifications()
                await model.loadTickets()
                await model.heartbeat()
                launcher.refreshLocalPackages()
                launcher.refreshResourceCheck()
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .gameSettings:
                TinplateGameSettingsSheet()
            case .packagePicker:
                PackageDocumentPicker { url in
                    activeSheet = nil
                    launcher.importPackage(url)
                }
            case .patchPicker:
                PackageDocumentPicker { url in
                    activeSheet = nil
                    launcher.importMobilePatch(url)
                }
            case .ticketComposer:
                TinplateTicketComposerSheet()
            case .notificationCenter:
                TinplateNotificationsSheet()
            case .announcements:
                TinplateAnnouncementsSheet()
            case .adaptationRequest:
                TinplateAdaptationRequestSheet()
            case .serviceSettings:
                TinplateServiceSettingsSheet()
            }
        }
        .fullScreenCover(isPresented: $showingGame) {
            if let root = launcher.gameRoot {
                GameView(root: root, entry: launcher.selectedEntry) {
                    showingGame = false
                }
            }
        }
    }

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                header
                banner
                featuredGameCard
                gameLibrary
                announcementsPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image("LauncherArt")
                .resizable()
                .scaledToFill()
                .frame(width: 49, height: 49)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                Text("你好，\(model.account?.displayName ?? model.username)")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(ink)
                Text("UID：\(model.account.map { String($0.id.prefix(8)) } ?? "—")")
                    .font(.system(size: 12))
                    .foregroundColor(muted)
            }
            Spacer()
            Button(action: {
                Task { await model.loadNotifications() }
                activeSheet = .notificationCenter
            }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 20))
                        .foregroundColor(muted)
                        .frame(width: 42, height: 42)
                        .background(Color.white)
                        .clipShape(Circle())
                    if model.unreadCount > 0 {
                        Circle().fill(Color.red).frame(width: 9, height: 9).offset(x: -5, y: 5)
                    }
                }
            }
            .accessibilityLabel("通知")
        }
        .padding(.vertical, 4)
    }

    private var banner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.07, green: 0.20, blue: 0.54),
                        Color(red: 0.10, green: 0.43, blue: 0.88),
                        Color(red: 0.37, green: 0.48, blue: 0.91)
                    ]),
                    startPoint: .leading, endPoint: .trailing
                ))
            Circle().fill(Color.white.opacity(0.10)).frame(width: 155).offset(x: 195, y: -42)
            Circle().fill(Color.white.opacity(0.08)).frame(width: 95).offset(x: 255, y: 55)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.selectedGame?.name ?? "小铁皮游戏库")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    Text("经典回归 · 再次启航")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.9))
                }
                Spacer()
                Image("LauncherArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .rotationEffect(.degrees(7))
                    .shadow(color: Color.black.opacity(0.22), radius: 12, y: 7)
                    .padding(.trailing, 8)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 154)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    private var featuredGameCard: some View {
        VStack(spacing: 13) {
            HStack(spacing: 12) {
                Image("LauncherArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.selectedGame?.name ?? "请选择游戏")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ink)
                    Text("游戏服务器：\(RuntimeServerSettings.configuredLogin?.address ?? "尚未设置")")
                        .font(.system(size: 12))
                        .foregroundColor(muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(muted)
            }

            HStack(spacing: 10) {
                Button(action: enterGame) {
                    Label("进入游戏", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(LinearGradient(
                            gradient: Gradient(colors: [Color(red: 0.03, green: 0.62, blue: 1), blue]),
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .clipShape(Capsule())
                }
                Button(action: { activeSheet = .gameSettings }) {
                    Label("游戏设置", systemImage: "gearshape.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white)
                        .overlay(Capsule().stroke(blue.opacity(0.35), lineWidth: 1.2))
                }
            }

            if !launcher.canStartGame {
                Text(!RuntimeServerSettings.isLoginConfigured
                     ? "请先设置当前游戏的登录服务器地址"
                     : "请前往「补丁」导入并校验游戏资源包")
                    .font(.system(size: 11))
                    .foregroundColor(muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(15)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(blue.opacity(0.07), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.025), radius: 10, y: 4)
    }

    private var gameLibrary: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("我的游戏库")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(ink)
                Spacer()
                Text("共 \(model.games.count) 款游戏")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(model.games) { game in
                        Button(action: { Task { await model.selectGame(game) } }) {
                            VStack(spacing: 6) {
                                Image("LauncherArt")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 55, height: 55)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                Text(game.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(ink)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(width: 88, height: 100)
                            .padding(7)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 17).stroke(
                                model.selectedGameSlug == game.slug ? blue : Color(red: 0.90, green: 0.93, blue: 0.98),
                                lineWidth: model.selectedGameSlug == game.slug ? 2 : 1
                            ))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    Button(action: { activeSheet = .adaptationRequest }) {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 26, weight: .medium))
                                .foregroundColor(muted)
                            Text("添加游戏")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(ink)
                        }
                        .frame(width: 88, height: 116)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color(red: 0.90, green: 0.93, blue: 0.98), lineWidth: 1))
                    }
                }
            }
            if model.games.isEmpty {
                Text("游戏库暂时为空，服务端发布游戏后会自动显示在这里。")
                    .font(.system(size: 12))
                    .foregroundColor(muted)
            }
        }
    }

    private var announcementsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("最新公告", systemImage: "megaphone.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(ink)
                Spacer()
                Button("更多") { activeSheet = .announcements }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(muted)
            }
            .padding(.bottom, 10)

            if model.announcements.isEmpty {
                Text("暂无公告")
                    .font(.system(size: 13))
                    .foregroundColor(muted)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(model.announcements.prefix(3))) { announcement in
                    Button(action: { activeSheet = .announcements }) {
                        HStack(spacing: 8) {
                            Circle().fill(blue.opacity(0.8)).frame(width: 6, height: 6)
                            Text(announcement.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(String(announcement.createdAt.prefix(10)).replacingOccurrences(of: "-", with: "/"))
                                .font(.system(size: 11))
                                .foregroundColor(muted)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    if announcement.id != model.announcements.prefix(3).last?.id {
                        Divider().opacity(0.35)
                    }
                }
            }
        }
        .padding(15)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19).stroke(blue.opacity(0.07), lineWidth: 1))
    }

    private var patchContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("补丁与资源")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(ink)
                    .padding(.top, 18)
                statusCard(title: "游戏资源包", detail: launcher.resourceCheckSummary, icon: "shippingbox.fill")
                Button(action: { activeSheet = .packagePicker }) {
                    Label("导入游戏资源包（.srom / .zip）", systemImage: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(blue)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
                Button(action: { activeSheet = .patchPicker }) {
                    Label("导入手机补丁（.sgpatch）", systemImage: "puzzlepiece.extension.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(blue)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 15).stroke(blue.opacity(0.35), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
                statusCard(title: "手机补丁状态", detail: launcher.patchStatus, icon: "puzzlepiece.fill")
                Button(action: { launcher.clearMobilePatch() }) {
                    Label("撤销手机补丁", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0.75, green: 0.25, blue: 0.31))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                statusCard(title: "当前状态", detail: launcher.status, icon: "info.circle.fill")
                if launcher.isImporting {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(launcher.importPhase)
                            Spacer()
                            Text("\(Int(launcher.importProgress * 100))%")
                        }
                        .font(.system(size: 12, weight: .medium))
                        ProgressView(value: launcher.importProgress)
                    }
                    .padding(14)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(18)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private var ticketsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("我的工单")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(ink)
                    Spacer()
                    Button(action: { activeSheet = .ticketComposer }) {
                        Label("新建工单", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(blue)
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 18)

                if model.tickets.isEmpty {
                    statusCard(title: "还没有工单", detail: "遇到登录、导入、闪退或补丁问题，可以在这里提交工单。", icon: "doc.text")
                } else {
                    ForEach(model.tickets) { ticket in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(ticket.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(ink)
                                Spacer()
                                Text(ticket.status)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(blue)
                            }
                            Text("\(ticket.category) · \(String(ticket.createdAt.prefix(10)))")
                                .font(.system(size: 12))
                                .foregroundColor(muted)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private var profileContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("我的")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(ink)
                    .padding(.top, 18)

                HStack(spacing: 13) {
                    Image("LauncherArt")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 62, height: 62)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.account?.displayName ?? model.username)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(ink)
                        Text("UID：\(model.account.map { String($0.id.prefix(8)) } ?? "—")")
                            .font(.system(size: 12))
                            .foregroundColor(muted)
                    }
                }
                .padding(15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 17))

                Button(action: { activeSheet = .serviceSettings }) {
                    Label("小铁皮服务端设置", systemImage: "server.rack")
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
                Button(action: { activeSheet = .gameSettings }) {
                    Label("当前游戏服务器设置", systemImage: "gamecontroller.fill")
                        .foregroundColor(ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
                Button(action: {
                    Task { await model.logout() }
                }) {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundColor(Color(red: 0.78, green: 0.22, blue: 0.28))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "首页", icon: "house.fill", index: 0)
            tabButton(title: "补丁", icon: "puzzlepiece.fill", index: 1)
            tabButton(title: "工单", icon: "doc.text.fill", index: 2)
            tabButton(title: "我的", icon: "person.fill", index: 3)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.white)
        .overlay(Rectangle().fill(Color.black.opacity(0.04)).frame(height: 1), alignment: .top)
    }

    private func tabButton(title: String, icon: String, index: Int) -> some View {
        Button(action: { selectedTab = index }) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 21, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(selectedTab == index ? blue : muted)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(selectedTab == index ? pale : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 5)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func statusCard(title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(blue)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundColor(ink)
                Text(detail).font(.system(size: 12)).foregroundColor(muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private func enterGame() {
        if !RuntimeServerSettings.isLoginConfigured {
            activeSheet = .gameSettings
        } else if !launcher.isInstalledValidated {
            selectedTab = 1
        } else if launcher.canStartGame {
            showingGame = true
        }
    }
}

struct TinplateServiceSettingsSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var address = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("小铁皮服务端")) {
                    TextField("https://你的服务端域名", text: $address)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Text("账号、密码、恢复码和登录令牌必须通过 HTTPS 传输。当前服务端源码标注的公网入口仍为 HTTP，不能安全用于真实账号注册。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Button("保存服务端地址") {
                        model.serverAddress = address
                        do {
                            try model.saveServerAddress()
                            Task {
                                await model.loadGames()
                                await model.loadAnnouncements()
                            }
                            presentationMode.wrappedValue.dismiss()
                        } catch {
                            model.status = error.localizedDescription
                        }
                    }
                }
            }
            .navigationBarTitle("服务端设置", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentationMode.wrappedValue.dismiss() })
        }
        .onAppear { address = model.serverAddress }
    }
}

struct TinplateGameSettingsSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var host = RuntimeServerSettings.configuredLogin?.host ?? ""
    @State private var port = RuntimeServerSettings.configuredLogin.map { String($0.port) } ?? ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(model.selectedGame.map { "\($0.name) · 游戏服务器" } ?? "游戏服务器")) {
                    TextField("服务器 IPv4 地址", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    Text("这里只设置当前游戏的登录服务器，不涉及小铁皮账号服务端，也不启用资源热更新。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Button("保存当前游戏服务器") {
                        model.saveCustomConnection(host: host, port: port)
                        if RuntimeServerSettings.isLoginConfigured {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    Button("恢复后台默认地址") {
                        Task {
                            await model.useDefaultConnection()
                            host = RuntimeServerSettings.configuredLogin?.host ?? ""
                            port = RuntimeServerSettings.configuredLogin.map { String($0.port) } ?? ""
                        }
                    }
                }
            }
            .navigationBarTitle("游戏设置", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentationMode.wrappedValue.dismiss() })
        }
        .onAppear {
            host = RuntimeServerSettings.configuredLogin?.host ?? ""
            port = RuntimeServerSettings.configuredLogin.map { String($0.port) } ?? ""
        }
    }
}

struct TinplateRecoveryCodeSheet: View {
    let code: String
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Image(systemName: "key.fill")
                    .font(.system(size: 38))
                    .foregroundColor(Color(red: 0.08, green: 0.42, blue: 0.98))
                Text("请保存账号恢复码")
                    .font(.system(size: 21, weight: .bold))
                Text("该恢复码只显示这一次。忘记密码时需要使用它找回账号，请勿发送给他人。")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Text(code)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(red: 0.08, green: 0.15, blue: 0.31))
                    .padding(15)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.95, green: 0.97, blue: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .textSelection(.enabled)
                Button(action: { UIPasteboard.general.string = code }) {
                    Label("复制恢复码", systemImage: "doc.on.doc")
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(red: 0.06, green: 0.42, blue: 0.98))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(22)
            .navigationBarTitle("账号安全", displayMode: .inline)
            .navigationBarItems(trailing: Button("我已保存") { presentationMode.wrappedValue.dismiss() })
        }
    }
}

struct TinplateRecoveryPasswordSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var username = ""
    @State private var recoveryCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("使用恢复码找回密码")) {
                    TextField("用户名", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("43 位恢复码", text: $recoveryCode)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("新密码（至少 12 位）", text: $newPassword)
                    SecureField("确认新密码", text: $confirmPassword)
                }
                Section {
                    Button("重置密码") {
                        guard newPassword == confirmPassword else {
                            model.status = "找回失败：两次输入的新密码不一致"
                            return
                        }
                        Task {
                            await model.recoverPassword(username: username, recoveryCode: recoveryCode, newPassword: newPassword)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    .disabled(model.isBusy || username.isEmpty || recoveryCode.isEmpty || newPassword.isEmpty)
                }
                Section {
                    Text(model.status).font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationBarTitle("忘记密码", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentationMode.wrappedValue.dismiss() })
        }
    }
}

struct TinplateTicketComposerSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var category = "OTHER"
    @State private var title = ""
    @State private var description = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("问题类型")) {
                    Picker("分类", selection: $category) {
                        Text("登录问题").tag("LOGIN")
                        Text("游戏闪退").tag("CRASH")
                        Text("资源导入").tag("IMPORT")
                        Text("运行性能").tag("PERFORMANCE")
                        Text("补丁问题").tag("PATCH")
                        Text("操作问题").tag("OPERATION")
                        Text("功能建议").tag("SUGGESTION")
                        Text("其他").tag("OTHER")
                    }
                }
                Section(header: Text("工单内容")) {
                    TextField("标题（3–120 字）", text: $title)
                    TextEditor(text: $description).frame(minHeight: 130)
                }
                Section {
                    Button("提交工单") {
                        Task {
                            await model.createTicket(category: category, title: title, description: description)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 ||
                              description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                }
            }
            .navigationBarTitle("新建工单", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentationMode.wrappedValue.dismiss() })
        }
    }
}

struct TinplateAdaptationRequestSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var gameName = ""
    @State private var description = ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("申请适配新游戏")) {
                    TextField("游戏名称", text: $gameName)
                    TextEditor(text: $description).frame(minHeight: 130)
                    Text("提交后由管理员审核；申请不代表一定会完成适配。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Button("提交适配申请") {
                        Task {
                            await model.submitAdaptationApplication(gameName: gameName, description: description)
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    .disabled(gameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                }
            }
            .navigationBarTitle("添加游戏", displayMode: .inline)
            .navigationBarItems(leading: Button("取消") { presentationMode.wrappedValue.dismiss() })
        }
    }
}

struct TinplateAnnouncementsSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                ForEach(model.announcements) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.system(size: 16, weight: .bold))
                        Text(item.content).font(.system(size: 13)).foregroundColor(.secondary)
                        Text(String(item.createdAt.prefix(10)))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 7)
                }
            }
            .navigationBarTitle("全部公告", displayMode: .inline)
            .navigationBarItems(leading: Button("关闭") { presentationMode.wrappedValue.dismiss() })
        }
        .onAppear { Task { await model.loadAnnouncements() } }
    }
}

struct TinplateNotificationsSheet: View {
    @EnvironmentObject private var model: TinplateClientModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            List {
                ForEach(model.notifications) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.title).font(.system(size: 15, weight: .semibold))
                            Spacer()
                            if item.readAt == nil {
                                Circle().fill(Color(red: 0.08, green: 0.42, blue: 0.98)).frame(width: 7, height: 7)
                            }
                        }
                        Text(item.body).font(.system(size: 13)).foregroundColor(.secondary)
                        Text(String(item.createdAt.prefix(10))).font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationBarTitle("消息通知", displayMode: .inline)
            .navigationBarItems(
                leading: Button("关闭") { presentationMode.wrappedValue.dismiss() },
                trailing: Button("全部已读") { Task { await model.markNotificationsRead() } }
            )
        }
        .onAppear { Task { await model.loadNotifications() } }
    }
}

