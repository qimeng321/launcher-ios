import Foundation
import Network

/// Local WebSocket-to-TCP relay for a browser-based Flash client.
final class GameSocketBridge {
    // Retain one listener set per app process: no rebinding while a prior
    // GameView's Network.framework cancellation is still in flight.
    private static let sharedLock = NSLock()
    private static var retainedBridge: GameSocketBridge?
    static func shared() throws -> GameSocketBridge {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let bridge = retainedBridge { return bridge }
        let bridge = try GameSocketBridge()
        retainedBridge = bridge
        return bridge
    }

    func leaveGame() {
        queue.async { [weak self] in
            guard let self else { return }
            let old = Array(self.sessions.values)
            old.forEach { $0.stop("已退出游戏：清理旧 Socket 连接") }
            self.gameEnteredFlag = false
            self.activeChannels.removeAll()
            self.activeRoomHost = nil
            self.activeRoomPort = nil
            LaunchDiagnostics.log("[页面生命周期] 已清理旧游戏会话；保留本地监听供再次进入")
        }
    }

    // Mutable on launcher home screen; no more re-signing an IPA for a host change.
    static var serverHost: String { RuntimeServerSettings.login.host }
    static var serverPort: UInt16 { RuntimeServerSettings.login.port }
    static let localPort: UInt16 = 32973
    // Distinct virtual port for the dynamically advertised game channel.
    // Ruffle matches the SWF's host+port exactly; the local gateway then
    // connects to the original channel port returned by CMD105/106.
    static let virtualChannelPort: UInt16 = 22974
    static let localChannelPort: UInt16 = 32974
    static let maxServerChannels = 20
    static func virtualChannelPort(for index: Int) -> UInt16 {
        index == 0 ? virtualChannelPort : UInt16(23000 + index)
    }
    static func localChannelPort(for index: Int) -> UInt16 {
        index == 0 ? localChannelPort : UInt16(33000 + index)
    }
    // GET_ROOM_ADDRES (10002) advertises an independent room socket.
    static let virtualRoomPort: UInt16 = 22975
    static let localRoomPort: UInt16 = 32975

    private let queue = DispatchQueue(label: "cn.qimeng321.independentlauncher.socket")
    private let listener: NWListener
    private let channelListener: NWListener
    private let roomListener: NWListener
    private var activeChannels: [Int: (host: String, port: UInt16)] = [:]
    private var additionalChannelListeners: [NWListener] = []
    private var activeRoomHost: String?
    private var activeRoomPort: UInt16?
    private var sessions: [UUID: Session] = [:]
    private var acceptedCount = 0
    private var gameEnteredFlag=false
    var hasEnteredGame: Bool { queue.sync { gameEnteredFlag } }
    // A new Flash document must NEVER inherit a previous session's success.
    // Keep live socket cleanup independent; a closing WebSocket may still
    // deliver its terminal callback after the new page starts.
    func resetGameEntryForNewPage() {
        queue.sync { gameEnteredFlag = false }
        LaunchDiagnostics.log("[页面生命周期] 新游戏页面：已重置旧选服成功标志")
    }
    private var remoteProbe: NWConnection?
    var hasReceivedClient: Bool { queue.sync { acceptedCount > 0 } }
    // Access state through the listener queue, because the UI polls from the
    // main thread while NWListener updates arrive on `queue`.
    private var readyFlag = false
    private var failureReason: String?
    var isReady: Bool { queue.sync { readyFlag } }
    var failureDescription: String? { queue.sync { failureReason } }

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        // `requiredLocalEndpoint` plus `on: <same port>` has been observed
        // to produce EINVAL (error 22) when constructing NWListener.
        // Bind to the loopback interface without specifying the port twice.
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.localPort)!)
        let channelOptions = NWProtocolWebSocket.Options()
        channelOptions.autoReplyPing = true
        channelOptions.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let channelParameters = NWParameters.tcp
        channelParameters.defaultProtocolStack.applicationProtocols.insert(channelOptions, at: 0)
        channelParameters.requiredInterfaceType = .loopback
        channelListener = try NWListener(using: channelParameters,
            on: NWEndpoint.Port(rawValue: Self.localChannelPort)!)
        let roomOptions = NWProtocolWebSocket.Options()
        roomOptions.autoReplyPing = true
        roomOptions.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let roomParameters = NWParameters.tcp
        roomParameters.defaultProtocolStack.applicationProtocols.insert(roomOptions, at: 0)
        roomParameters.requiredInterfaceType = .loopback
        roomListener = try NWListener(using: roomParameters,
            on: NWEndpoint.Port(rawValue: Self.localRoomPort)!)
        // Each selectable channel needs a unique virtual WebSocket port.
        for channelIndex in 1..<Self.maxServerChannels {
            let channelOptions = NWProtocolWebSocket.Options()
            channelOptions.autoReplyPing = true
            channelOptions.setClientRequestHandler(queue) { _, _ in
                NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            }
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(channelOptions, at: 0)
            parameters.requiredInterfaceType = .loopback
            let port = Self.localChannelPort(for: channelIndex)
            let extra = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            extra.newConnectionHandler = { [weak self] webSocket in
                guard let self else { webSocket.cancel(); return }
                self.acceptChannel(webSocket, serverIndex: channelIndex)
            }
            extra.stateUpdateHandler = { state in
                switch state {
                case .ready: LaunchDiagnostics.log("[1.11频道代理] 频道\(channelIndex + 1) 监听就绪：\(port)")
                case .failed(let error): LaunchDiagnostics.log("[1.11频道代理] 频道\(channelIndex + 1) 监听失败：" + error.localizedDescription)
                default: break
                }
            }
            additionalChannelListeners.append(extra)
        }
        roomListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                LaunchDiagnostics.log("[基地代理] 本地 WebSocket 监听成功 32975，虚拟基地端口 22975")
            case .failed(let error):
                self?.failureReason = "基地代理启动失败 [32975]：\(error.localizedDescription)"
                LaunchDiagnostics.log("[基地代理] 本地监听失败：" + error.localizedDescription)
            case .waiting(let error):
                LaunchDiagnostics.log("[基地代理] 等待中：" + error.localizedDescription)
            default: break
            }
        }
        channelListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                LaunchDiagnostics.log("[频道代理] 本地 WebSocket 监听成功 32974，虚拟游戏端口 22974")
            case .failed(let error):
                LaunchDiagnostics.log("[频道代理] 本地监听失败：" + error.localizedDescription)
            case .waiting(let error):
                LaunchDiagnostics.log("[频道代理] 等待中：" + error.localizedDescription)
            default: break
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                LaunchDiagnostics.log("本地 WebSocket 代理就绪，端口：32973")
                self?.readyFlag = true
                self?.failureReason = nil
                self?.probeRemoteServer()
            case .failed(let error):
                LaunchDiagnostics.log("本地 WebSocket 代理失败：\(error.localizedDescription)")
                self?.readyFlag = false
                self?.failureReason = "本地 WebSocket 代理启动失败 [32973]：\(error.localizedDescription)"
            case .waiting(let error):
                LaunchDiagnostics.log("本地 WebSocket 代理等待：\(error.localizedDescription)")
                self?.readyFlag = false
                self?.failureReason = "本地 WebSocket 代理等待网络 [32973]：\(error.localizedDescription)"
            case .cancelled:
                self?.readyFlag = false
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] webSocket in
            LaunchDiagnostics.log("Flash WebSocket 代理收到新的本地连接")
            guard let self else { webSocket.cancel(); return }
            self.acceptedCount += 1
            let id = UUID()
            let session = Session(webSocket: webSocket, queue: self.queue,
                                  index: self.acceptedCount,
                                  remoteHost: Self.serverHost,
                                  remotePort: Self.serverPort,
                                  onChannel: { [weak self] channelIndex, host, port in
                                      guard let self else { return }
                                      self.activeChannels[channelIndex] = (host: host, port: port)
                                      LaunchDiagnostics.log("[1.11频道发现] 频道\(channelIndex + 1) 原始地址：" + host + ":" + String(port))
                                  },
                                  onEnterGame: { [weak self] in self?.gameEnteredFlag = true },
                                  onRoom: { [weak self] host, port in
                                      self?.activeRoomHost = host
                                      self?.activeRoomPort = port
                                      LaunchDiagnostics.log("[基地发现] 服务器地址=" + host + ":" + String(port))
                                  }) { [weak self] in
                self?.sessions.removeValue(forKey: id)
            }
            self.sessions[id] = session
            session.start()
        }
        channelListener.newConnectionHandler = { [weak self] webSocket in
            guard let self else { webSocket.cancel(); return }
            self.acceptChannel(webSocket, serverIndex: 0)
        }
        roomListener.newConnectionHandler = { [weak self] webSocket in
            guard let self else { webSocket.cancel(); return }
            guard let host = self.activeRoomHost, let port = self.activeRoomPort else {
                LaunchDiagnostics.log("[基地代理] 收到连接，但尚未取得有效的 GET_ROOM_ADDRES 地址")
                webSocket.cancel()
                return
            }
            self.acceptedCount += 1
            let id = UUID()
            let session = Session(webSocket: webSocket, queue: self.queue,
                                  index: self.acceptedCount,
                                  remoteHost: host, remotePort: port,
                                  onChannel: { _, _, _ in },
                                  onEnterGame: {},
                                  onRoom: { _, _ in }) { [weak self] in
                self?.sessions.removeValue(forKey: id)
            }
            self.sessions[id] = session
            LaunchDiagnostics.log("[基地代理] 将基地连接转发至服务器 " + host + ":" + String(port))
            session.start()
        }
        listener.start(queue: queue)
        channelListener.start(queue: queue)
        additionalChannelListeners.forEach { $0.start(queue: queue) }
        roomListener.start(queue: queue)
    }

    private func acceptChannel(_ webSocket: NWConnection, serverIndex: Int) {
        guard let destination = activeChannels[serverIndex] else {
            LaunchDiagnostics.log("[1.11选服] 频道\(serverIndex + 1) 尚无服务器地址，拒绝连接")
            webSocket.cancel()
            return
        }
        acceptedCount += 1
        let id = UUID()
        LaunchDiagnostics.log("[1.11选服] 频道\(serverIndex + 1)，虚拟端口=\(Self.virtualChannelPort(for: serverIndex))，真实地址=" +
            destination.host + ":" + String(destination.port))
        let session = Session(webSocket: webSocket, queue: queue,
                              index: acceptedCount,
                              remoteHost: destination.host,
                              remotePort: destination.port,
                              onChannel: { _, _, _ in },
                              onEnterGame: { [weak self] in self?.gameEnteredFlag = true },
                              onRoom: { [weak self] host, port in
                                  self?.activeRoomHost = host
                                  self?.activeRoomPort = port
                                  LaunchDiagnostics.log("[基地发现] 服务器地址=" + host + ":" + String(port))
                              }) { [weak self] in
            self?.sessions.removeValue(forKey: id)
        }
        sessions[id] = session
        session.start()
    }

    deinit {
        listener.cancel()
        channelListener.cancel()
        additionalChannelListeners.forEach { $0.cancel() }
        roomListener.cancel()
        remoteProbe?.cancel()
        sessions.values.forEach { $0.stop() }
    }

    private func probeRemoteServer() {
        // TCP connect only: do not transmit authentication data or game packets.
        let probe = NWConnection(host: NWEndpoint.Host(Self.serverHost),
            port: NWEndpoint.Port(rawValue: Self.serverPort)!, using: .tcp)
        remoteProbe = probe
        probe.stateUpdateHandler = { [weak self, weak probe] state in
            guard let self, let probe, self.remoteProbe === probe else { return }
            switch state {
            case .ready:
                LaunchDiagnostics.log("[网络预检] 线上 TCP 服务器可连接（不代表登录成功）")
                self.remoteProbe = nil
                probe.cancel()
            case .failed(let error):
                LaunchDiagnostics.log("[网络预检] 线上 TCP 服务器连接失败：" + error.localizedDescription)
                self.remoteProbe = nil
                probe.cancel()
            case .waiting(let error):
                LaunchDiagnostics.log("[网络预检] TCP 连接等待：" + error.localizedDescription)
            case .cancelled:
                self.remoteProbe = nil
            default: break
            }
        }
        probe.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak probe] in
            guard let self, let probe, self.remoteProbe === probe else { return }
            LaunchDiagnostics.log("[网络预检] 线上 TCP 连接超时（8秒）")
            self.remoteProbe = nil
            probe.cancel()
        }
    }

    private final class Session {
        private let webSocket: NWConnection
        private let tcp: NWConnection
        private let queue: DispatchQueue
        private let onClose: () -> Void
        private var closed = false
        private var loggedUpstreamBytes = false
        private var loggedDownstreamBytes = false
        private let index: Int
        private var upstreamCount=0
        private var downstreamCount=0
        private var upstreamTotal=0
        private var downstreamTotal=0
        private let onEnterGame: () -> Void
        private let onChannel: (Int, String, UInt16) -> Void
        private let onRoom: (String, UInt16) -> Void
        private let remoteHost: String
        private var downstreamFramer = GameProtocolFramer()
        private let remotePort: UInt16

        init(webSocket: NWConnection, queue: DispatchQueue, index: Int,
             remoteHost: String, remotePort: UInt16,
             onChannel: @escaping (Int, String, UInt16) -> Void,
             onEnterGame: @escaping () -> Void,
             onRoom: @escaping (String, UInt16) -> Void,
             onClose: @escaping () -> Void) {
            self.remoteHost = remoteHost
            self.remotePort = remotePort
            self.onChannel = onChannel
            self.onRoom = onRoom
            self.onEnterGame = onEnterGame
            self.index = index
            self.webSocket = webSocket
            self.queue = queue
            self.onClose = onClose
            self.tcp = NWConnection(
                host: NWEndpoint.Host(remoteHost),
                port: NWEndpoint.Port(rawValue: remotePort)!,
                using: .tcp
            )
        }

        func start() {
            webSocket.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    LaunchDiagnostics.log("[登录网络] 本地 WebSocket 握手完成")
                case .failed(let error):
                    LaunchDiagnostics.log("[登录网络] 本地 WebSocket 失败：" + error.localizedDescription)
                    self?.stop()
                case .waiting(let error):
                    LaunchDiagnostics.log("[登录网络] 本地 WebSocket 等待：" + error.localizedDescription)
                case .cancelled:
                    self?.stop()
                default: break
                }
            }
            tcp.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    LaunchDiagnostics.log("[登录网络] 远端 TCP 连接成功：" + (self?.remoteHost ?? "未知") + ":" + String(self?.remotePort ?? 0))
                case .failed(let error):
                    LaunchDiagnostics.log("[登录网络] 远端 TCP 连接失败：" + error.localizedDescription)
                    self?.stop()
                case .waiting(let error):
                    LaunchDiagnostics.log("远端 TCP 游戏服务器等待中：\(error.localizedDescription)")
                case .cancelled:
                    self?.stop()
                default: break
                }
            }
            webSocket.start(queue: queue)
            tcp.start(queue: queue)
            receiveWebSocket()
            receiveTCP()
        }

        func stop(_ reason: String = "会话关闭") {
            guard !closed else { return }
            closed = true
            LaunchDiagnostics.log("[会话#\(index)] \(reason)，上行\(upstreamCount)帧/\(upstreamTotal)字节，下行\(downstreamCount)帧/\(downstreamTotal)字节")
            webSocket.cancel()
            tcp.cancel()
            onClose()
        }

        private func receiveWebSocket() {
            webSocket.receiveMessage { [weak self] data, context, _, error in
                guard let self, !self.closed else { return }
                if let error {
                    self.stop("WebSocket 接收失败：" + error.localizedDescription)
                    return
                }
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                    self.stop("Flash 主动关闭 WebSocket")
                    return
                }
                guard let data else { self.receiveWebSocket(); return }
                self.upstreamCount += 1
                self.upstreamTotal += data.count
                // Header-only room diagnostics; no sensitive payload is logged.
                if data.count >= 9 {
                    let raw = [UInt8](data)
                    let cmd = self.uint32BE(raw, 5)
                    if cmd == 10002 || cmd == 10001 || cmd == 10003 {
                        LaunchDiagnostics.log("[基地协议] 上行 CMD\(cmd)，内容已隐藏")
                    }
                }
                if self.upstreamCount <= 4 || self.upstreamCount % 10 == 0 {
                    LaunchDiagnostics.log("[会话#\(self.index)] 上行#\(self.upstreamCount) \(data.count)字节（无负载）")
                }
                if !self.loggedUpstreamBytes {
                    self.loggedUpstreamBytes = true
                    LaunchDiagnostics.log("[登录网络] 首次 Flash→远端传输：" + String(data.count) + " 字节（不记录内容）")
                }
                self.tcp.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error { self?.stop("向远端写入失败：" + error.localizedDescription) }
                    else { self?.receiveWebSocket() }
                })
            }
        }


        private func uint32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            return UInt32(bytes[offset]) << 24 |
                   UInt32(bytes[offset + 1]) << 16 |
                   UInt32(bytes[offset + 2]) << 8 |
                   UInt32(bytes[offset + 3])
        }

        /// Inspect only non-sensitive protocol metadata and make selected game
        /// channel endpoints accessible through our fixed Ruffle socketProxy.
        /// Packet header: size(4) version(1) cmd(4) userID(4) result(4).
        /// Never log userID or payload bytes.
        private func mapServerList(_ data: Data) -> Data {
            var bytes = [UInt8](data)
            var cursor=0
            while cursor + 17 <= bytes.count {
                let packetSize=Int(uint32BE(bytes,cursor))
                guard packetSize>=17 && cursor+packetSize<=bytes.count else { break }
                let cmd=uint32BE(bytes,cursor+5)
                let result=uint32BE(bytes,cursor+13)
                if cmd == 1001 && result == 0 {
                    LaunchDiagnostics.log("[选服阶段] 收到 CMD1001 成功响应，进入游戏状态")
                    onEnterGame()
                }
                // RoomController: session[24] + IPv4[4] + port[2].
                if cmd == 10002 {
                    LaunchDiagnostics.log("[基地协议] GET_ROOM_ADDRES 下行；结果=\(result)；包字节=\(packetSize)")
                }
                if cmd == 10002 && result == 0 {
                    let address = cursor + 17 + 24
                    if address + 6 <= cursor + packetSize {
                        let octets = Array(bytes[address..<(address+4)])
                        let port = (UInt16(bytes[address+4]) << 8) | UInt16(bytes[address+5])
                        let host = octets.map { String($0) }.joined(separator: ".")
                        if port > 0 && octets[0] != 0 && octets[0] != 127 && octets[0] < 224 {
                            onRoom(host, port)
                            let virtualOctets = GameSocketBridge.serverHost.split(separator: ".").compactMap { UInt8($0) }
                            if virtualOctets.count == 4 {
                                for i in 0..<4 { bytes[address+i] = virtualOctets[i] }
                                bytes[address+4] = UInt8(GameSocketBridge.virtualRoomPort >> 8)
                                bytes[address+5] = UInt8(GameSocketBridge.virtualRoomPort & 255)
                                LaunchDiagnostics.log("[基地代理] GET_ROOM_ADDRES：已映射为虚拟 22975 端口，原目标=" + host + ":" + String(port))
                            }
                        } else {
                            LaunchDiagnostics.log("[基地代理] GET_ROOM_ADDRES 返回无效目标，未改写")
                        }
                    } else {
                        LaunchDiagnostics.log("[基地代理] GET_ROOM_ADDRES 数据长度不足")
                    }
                }
                if cmd == 105 || cmd == 106 {
                    let countOffset = cursor + 17 + (cmd == 105 ? 8 : 0)
                    let firstServer = countOffset + 4
                    if countOffset + 4 <= cursor + packetSize {
                        let count = Int(uint32BE(bytes, countOffset))
                        LaunchDiagnostics.log("[1.11服务器列表] CMD\(cmd)，条目数=\(count)，结果=\(result)，包长度=\(packetSize)")
                        // Latest 2026111703 Login.swf ServerInfo is 62 bytes:
                        // OnlineID(4) UserCnt(4) IP(16) Port(2) Friends(4) Name(32).
                        let payloadLength = cursor + packetSize - firstServer
                        let entryLength = count > 0 && payloadLength == count * 30 ? 30 : 62
                        if result == 0 && count > 0 &&
                            count <= GameSocketBridge.maxServerChannels &&
                            firstServer + count * entryLength <= cursor + packetSize {
                            let virtualHost = Array(GameSocketBridge.serverHost.utf8)
                            for channelIndex in 0..<count {
                                let entry = firstServer + channelIndex * entryLength
                                let onlineID = uint32BE(bytes, entry)
                                let hostBytes = bytes[(entry + 8)..<(entry + 24)]
                                let host = String(decoding: hostBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                                let port = (UInt16(bytes[entry + 24]) << 8) | UInt16(bytes[entry + 25])
                                let segments = host.split(separator: ".", omittingEmptySubsequences: false)
                                let isIPv4 = segments.count == 4 && segments.allSatisfy { segment in
                                    guard let byte = UInt8(segment) else { return false }
                                    return String(byte) == String(segment)
                                }
                                if isIPv4 && port > 0 {
                                    onChannel(channelIndex, host, port)
                                    for j in 0..<16 {
                                        bytes[entry + 8 + j] = j < virtualHost.count ? virtualHost[j] : 0
                                    }
                                    let virtualPort = GameSocketBridge.virtualChannelPort(for: channelIndex)
                                    bytes[entry + 24] = UInt8(virtualPort >> 8)
                                    bytes[entry + 25] = UInt8(virtualPort & 255)
                                    LaunchDiagnostics.log("[1.11服务器列表] 频道\(channelIndex + 1) ID=\(onlineID)，目标=" +
                                        host + ":" + String(port) + "，映射端口=" + String(virtualPort))
                                } else {
                                    LaunchDiagnostics.log("[1.11服务器列表] 频道\(channelIndex + 1) ID=\(onlineID) 目标异常，保留原字节")
                                }
                            }
                        } else {
                            LaunchDiagnostics.log("[1.11服务器列表] 数据长度或频道数与已知30/62字节结构不符，未做映射")
                        }
                    }
                } else if downstreamCount <= 4 {
                    LaunchDiagnostics.log("[游戏协议] 下行命令=\(cmd)，包字节=\(packetSize)，结果=\(result)")
                }
                cursor += packetSize
            }
            return Data(bytes)
        }
        private func receiveTCP() {
            tcp.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                if let error {
                    self.stop("远端读取失败：" + error.localizedDescription)
                    return
                }
                // FIN may arrive with data. The previous implementation
                // returned on complete before forwarding the final payload.
                guard let data, !data.isEmpty else {
                    if complete {
                        let remainder = self.downstreamFramer.flushRemainder()
                        if !remainder.isEmpty {
                            let ctx = NWConnection.ContentContext(identifier: "binary",
                                metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
                            self.webSocket.send(content: remainder, contentContext: ctx, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in
                                    self?.stop("远端 TCP FIN：已转发残留数据")
                                })
                        } else { self.stop("远端 TCP FIN（无附带数据）") }
                    } else { self.receiveTCP() }
                    return
                }
                self.downstreamCount += 1
                self.downstreamTotal += data.count
                if self.downstreamCount <= 5 || self.downstreamCount % 10 == 0 {
                    LaunchDiagnostics.log("[会话#\(self.index)] 下行#\(self.downstreamCount) \(data.count)字节，尾包FIN=\(complete)（无负载）")
                }
                if !self.loggedDownstreamBytes {
                    self.loggedDownstreamBytes = true
                    LaunchDiagnostics.log("[登录网络] 首次远端→Flash 传输：" + String(data.count) + " 字节（不记录内容）")
                }
                var mapped = self.downstreamFramer.consume(data, rewrite: { [weak self] frame in
                    self?.mapServerList(frame) ?? frame
                }, onAnomaly: { issue in
                    LaunchDiagnostics.log("[网络帧重组] " + issue)
                })
                if complete { mapped.append(self.downstreamFramer.flushRemainder()) }
                if mapped.isEmpty {
                    if complete { self.stop("远端 FIN：剩余数据已处理") }
                    else { self.receiveTCP() }
                    return
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
                self.webSocket.send(content: mapped, contentContext: context, isComplete: true,
                                    completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error {
                        self.stop("下行 WebSocket 转发失败：" + error.localizedDescription)
                    } else if complete {
                        self.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.stop("远端带数据 FIN：已转发尾包")
                        }
                    } else {
                        self.receiveTCP()
                    }
                })
            }
        }
    }
}
