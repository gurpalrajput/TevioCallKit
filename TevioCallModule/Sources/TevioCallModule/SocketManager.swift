import Foundation
import SocketIO

public final class SocketManager: NSObject, CallTransporting {
    public enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    public struct Configuration {
        public typealias StatusChannelNameProvider = (String) -> String

        public let socketURL: URL
        public let path: String
        public let namespace: String
        public let headers: [String: String]
        public let connectParams: [String: Any]
        public let statusEventName: String
        public let statusChannelNameProvider: StatusChannelNameProvider?
        public let subscribeEventName: String?
        public let unsubscribeEventName: String?
        public let enableLogging: Bool
        public let reconnects: Bool

        public init(
            socketURL: URL,
            path: String = "/socket.io/",
            namespace: String = "/",
            headers: [String: String] = [:],
            connectParams: [String: Any] = [:],
            statusEventName: String = "call-status",
            statusChannelNameProvider: StatusChannelNameProvider? = nil,
            subscribeEventName: String? = "call-subscribe",
            unsubscribeEventName: String? = "call-unsubscribe",
            enableLogging: Bool = false,
            reconnects: Bool = true
        ) {
            self.socketURL = socketURL
            self.path = path
            self.namespace = namespace
            self.headers = headers
            self.connectParams = connectParams
            self.statusEventName = statusEventName
            self.statusChannelNameProvider = statusChannelNameProvider
            self.subscribeEventName = subscribeEventName
            self.unsubscribeEventName = unsubscribeEventName
            self.enableLogging = enableLogging
            self.reconnects = reconnects
        }
    }

    public var onStateChange: ((ConnectionState) -> Void)?
    public var onRawEvent: ((String, [Any]) -> Void)?

    private let configuration: Configuration
    private let callbackQueue: DispatchQueue
    private let manager: SocketIO.SocketManager
    private let socket: SocketIOClient
    private var handlersByThreadID: [String: (RemoteCallStatusEvent) -> Void] = [:]
    private var dynamicListeners: [String: ([String: Any]) -> Void] = [:]
    private var pendingStatusPayloads: [[String: Any]] = []
    private var pendingSubscriptions = Set<String>()
    private var isManuallyClosed = false
    private var currentState: ConnectionState = .idle {
        didSet {
            callbackQueue.async { [currentState, onStateChange] in
                onStateChange?(currentState)
            }
        }
    }

    public init(
        configuration: Configuration,
        callbackQueue: DispatchQueue = .main
    ) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
        self.manager = SocketIO.SocketManager(
            socketURL: configuration.socketURL,
            config: [
                .path(configuration.path),
                .connectParams(configuration.connectParams),
                .extraHeaders(configuration.headers),
                .log(configuration.enableLogging),
                .reconnects(configuration.reconnects),
                .compress,
                .forceWebsockets(true)
            ]
        )
        self.socket = manager.socket(forNamespace: configuration.namespace)
        super.init()
        registerBaseHandlers()
    }

    deinit {
        disconnect()
    }

    public func connectIfNeeded() {
        switch socket.status {
        case .connected, .connecting:
            return
        default:
            isManuallyClosed = false
            currentState = .connecting
            socket.connect()
        }
    }

    public func establishConnection(onConnected: (() -> Void)? = nil) {
        if let onConnected {
            socket.once(clientEvent: .connect) { _, _ in
                onConnected()
            }
        }
        connectIfNeeded()
    }

    public func disconnect() {
        isManuallyClosed = true
        unsubscribeAllIfNeeded()
        removeDynamicListeners()
        removePendingWork()
        socket.disconnect()
        currentState = .disconnected
    }

    public func closeConnection() {
        disconnect()
    }

    public func getSocket() -> SocketIOClient {
        socket
    }

    public func emit(status: CallStatus, threadId: String, completion: (() -> Void)?) {
        let payload: [String: Any] = [
            "thread_id": threadId,
            "status": status.rawValue
        ]

        connectIfNeeded()
        if socket.status == .connected {
            socket.emit(configuration.statusEventName, payload)
        } else {
            pendingStatusPayloads.append(payload)
        }
        completion?()
    }

    public func startListening(threadId: String, handler: @escaping (RemoteCallStatusEvent) -> Void) {
        handlersByThreadID[threadId] = handler
        pendingSubscriptions.insert(threadId)
        connectIfNeeded()
        attachStatusChannelListenerIfNeeded(threadId: threadId)
        subscribeIfNeeded(threadId: threadId)
    }

    public func stopListening(threadId: String?) {
        if let threadId {
            handlersByThreadID.removeValue(forKey: threadId)
            pendingSubscriptions.remove(threadId)
            removeStatusChannelListenerIfNeeded(threadId: threadId)
            unsubscribeIfNeeded(threadId: threadId)
            return
        }

        unsubscribeAllIfNeeded()
        removePendingWork()
    }

    public func listen(on channel: String, callback: @escaping ([String: Any]) -> Void) {
        dynamicListeners[channel] = callback
        socket.off(channel)
        socket.on(channel) { [weak self] data, _ in
            guard
                let self,
                let payload = data.first as? [String: Any]
            else {
                return
            }

            self.notifyRawEvent(name: channel, items: data)
            self.dynamicListeners[channel]?(payload)
        }
    }

    public func removeListener(for channel: String) {
        socket.off(channel)
        dynamicListeners.removeValue(forKey: channel)
    }

    private func registerBaseHandlers() {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            self.currentState = .connected
            self.flushPendingStatusPayloads()
            self.resubscribeAllThreads()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self else { return }
            let message = (data.first as? String) ?? "Socket disconnected"
            self.currentState = .disconnected
            self.notifyRawEvent(name: SocketClientEvent.disconnect.rawValue, items: data)
            if !message.isEmpty, message != "Disconnect" {
                self.notifyState(.failed(message))
            }
            if !self.isManuallyClosed, self.socket.status != .connected, self.configuration.reconnects {
                self.socket.connect()
            }
        }

        socket.on(clientEvent: .error) { [weak self] data, _ in
            guard let self else { return }
            let message = (data.first as? String) ?? "Socket error"
            self.currentState = .failed(message)
            self.notifyRawEvent(name: SocketClientEvent.error.rawValue, items: data)
        }

        socket.on(clientEvent: .reconnect) { [weak self] data, _ in
            guard let self else { return }
            self.currentState = .connected
            self.notifyRawEvent(name: SocketClientEvent.reconnect.rawValue, items: data)
            self.flushPendingStatusPayloads()
            self.resubscribeAllThreads()
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            guard let self else { return }
            self.currentState = .connecting
            self.notifyRawEvent(name: SocketClientEvent.reconnectAttempt.rawValue, items: data)
        }

        socket.on(clientEvent: .statusChange) { [weak self] data, _ in
            guard let self else { return }
            self.notifyRawEvent(name: SocketClientEvent.statusChange.rawValue, items: data)
            guard let rawStatus = data.first as? String else { return }
            switch rawStatus {
            case "connected":
                self.currentState = .connected
            case "connecting":
                self.currentState = .connecting
            case "disconnected", "notConnected":
                self.currentState = .disconnected
            default:
                break
            }
        }

        socket.on(configuration.statusEventName) { [weak self] data, _ in
            self?.handle(eventName: self?.configuration.statusEventName ?? "", items: data)
        }

        for status in CallStatus.allCases {
            socket.on(status.rawValue) { [weak self] data, _ in
                self?.handle(eventName: status.rawValue, items: data)
            }
        }
    }

    private func handle(eventName: String, items: [Any]) {
        notifyRawEvent(name: eventName, items: items)

        guard let event = makeRemoteCallStatusEvent(eventName: eventName, items: items) else { return }
        handlersByThreadID[event.threadId]?(event)
    }

    private func makeRemoteCallStatusEvent(eventName: String, items: [Any]) -> RemoteCallStatusEvent? {
        let payload = items.compactMap { $0 as? [String: Any] }.first
        let threadId = payload?["thread_id"] as? String ?? payload?["threadId"] as? String
        let statusValue = payload?["status"] as? String
            ?? payload?["type"] as? String
            ?? rawStatusValue(fromEventName: eventName)

        guard
            let threadId,
            let statusValue,
            let status = CallStatus(rawValue: statusValue)
        else {
            return nil
        }

        return RemoteCallStatusEvent(threadId: threadId, status: status)
    }

    private func rawStatusValue(fromEventName eventName: String) -> String? {
        if CallStatus(rawValue: eventName) != nil {
            return eventName
        }

        if eventName == configuration.statusEventName {
            return nil
        }

        return nil
    }

    private func subscribeIfNeeded(threadId: String) {
        guard
            socket.status == .connected,
            let subscribeEventName = configuration.subscribeEventName,
            configuration.statusChannelNameProvider == nil
        else {
            return
        }

        socket.emit(subscribeEventName, ["thread_id": threadId])
    }

    private func unsubscribeIfNeeded(threadId: String) {
        guard
            socket.status == .connected,
            let unsubscribeEventName = configuration.unsubscribeEventName,
            configuration.statusChannelNameProvider == nil
        else {
            return
        }

        socket.emit(unsubscribeEventName, ["thread_id": threadId])
    }

    private func resubscribeAllThreads() {
        pendingSubscriptions.forEach(subscribeIfNeeded(threadId:))
    }

    private func flushPendingStatusPayloads() {
        guard socket.status == .connected else { return }
        let payloads = pendingStatusPayloads
        pendingStatusPayloads.removeAll()
        payloads.forEach { payload in
            socket.emit(configuration.statusEventName, payload)
        }
    }

    private func unsubscribeAllIfNeeded() {
        let threadIDs = Array(handlersByThreadID.keys)
        handlersByThreadID.removeAll()
        threadIDs.forEach(unsubscribeIfNeeded(threadId:))
    }

    private func removePendingWork() {
        handlersByThreadID.removeAll()
        pendingSubscriptions.removeAll()
        pendingStatusPayloads.removeAll()
    }

    private func attachStatusChannelListenerIfNeeded(threadId: String) {
        guard let channelNameProvider = configuration.statusChannelNameProvider else { return }
        let channel = channelNameProvider(threadId)
        socket.off(channel)
        socket.on(channel) { [weak self] data, _ in
            self?.handle(eventName: channel, items: data)
        }
    }

    private func removeStatusChannelListenerIfNeeded(threadId: String) {
        guard let channelNameProvider = configuration.statusChannelNameProvider else { return }
        socket.off(channelNameProvider(threadId))
    }

    private func removeDynamicListeners() {
        dynamicListeners.keys.forEach { socket.off($0) }
        dynamicListeners.removeAll()
    }

    private func notifyRawEvent(name: String, items: [Any]) {
        callbackQueue.async { [onRawEvent] in
            onRawEvent?(name, items)
        }
    }

    private func notifyState(_ state: ConnectionState) {
        callbackQueue.async { [onStateChange] in
            onStateChange?(state)
        }
    }
}
