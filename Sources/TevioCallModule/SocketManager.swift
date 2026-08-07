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
            statusEventName: String = "call:status-1",
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
            self.connectParams = SocketManager.sanitizedJSONObject(connectParams)
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
    private var pendingConnectionRequests: [UUID: (Bool) -> Void] = [:]
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
            debugLog("connectIfNeeded skipped; socket status=\(socket.status)")
            return
        default:
            isManuallyClosed = false
            currentState = .connecting
            debugLog("connectIfNeeded connecting socket to \(configuration.socketURL.absoluteString) namespace=\(configuration.namespace)")
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

    public func ensureConnected(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        if socket.status == .connected {
            completion(true)
            return
        }

        let requestID = UUID()
        pendingConnectionRequests[requestID] = completion
        connectIfNeeded()

        callbackQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let callback = self.pendingConnectionRequests.removeValue(forKey: requestID) else { return }
            callback(false)
        }
    }

    public func disconnect() {
        isManuallyClosed = true
        debugLog("disconnect requested")
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
            emitEvent(configuration.statusEventName, payload: payload, context: "status")
        } else {
            pendingStatusPayloads.append(payload)
            debugLog("queued emit event=\(configuration.statusEventName) payload=\(stringify(payload)) reason=socket_not_connected status=\(socket.status)")
        }
        completion?()
    }

    public func startListening(threadId: String, handler: @escaping (RemoteCallStatusEvent) -> Void) {
        handlersByThreadID[threadId] = handler
        pendingSubscriptions.insert(threadId)
        debugLog("startListening threadId=\(threadId)")
        connectIfNeeded()
        attachStatusChannelListenerIfNeeded(threadId: threadId)
        subscribeIfNeeded(threadId: threadId)
    }

    public func stopListening(threadId: String?) {
        if let threadId {
            debugLog("stopListening threadId=\(threadId)")
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
        debugLog("register listener channel=\(channel)")
        socket.off(channel)
        socket.on(channel) { [weak self] data, _ in
            guard
                let self,
                let payload = data.first as? [String: Any]
            else {
                return
            }

            self.debugLog("listener called channel=\(channel) payload=\(self.stringify(payload))")
            self.notifyRawEvent(name: channel, items: data)
            self.dynamicListeners[channel]?(payload)
        }
    }

    public func removeListener(for channel: String) {
        debugLog("remove listener channel=\(channel)")
        socket.off(channel)
        dynamicListeners.removeValue(forKey: channel)
    }

    private func registerBaseHandlers() {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            self.debugLog("client event connect")
            self.currentState = .connected
            let callbacks = self.pendingConnectionRequests.values
            self.pendingConnectionRequests.removeAll()
            callbacks.forEach { $0(true) }
            self.flushPendingStatusPayloads()
            self.resubscribeAllThreads()
        }

        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            guard let self else { return }
            let message = (data.first as? String) ?? "Socket disconnected"
            self.debugLog("client event disconnect payload=\(self.stringify(data))")
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
            self.debugLog("client event error payload=\(self.stringify(data))")
            self.currentState = .failed(message)
            let callbacks = self.pendingConnectionRequests.values
            self.pendingConnectionRequests.removeAll()
            callbacks.forEach { $0(false) }
            self.notifyRawEvent(name: SocketClientEvent.error.rawValue, items: data)
        }

        socket.on(clientEvent: .reconnect) { [weak self] data, _ in
            guard let self else { return }
            self.debugLog("client event reconnect payload=\(self.stringify(data))")
            self.currentState = .connected
            self.notifyRawEvent(name: SocketClientEvent.reconnect.rawValue, items: data)
            self.flushPendingStatusPayloads()
            self.resubscribeAllThreads()
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            guard let self else { return }
            self.debugLog("client event reconnectAttempt payload=\(self.stringify(data))")
            self.currentState = .connecting
            self.notifyRawEvent(name: SocketClientEvent.reconnectAttempt.rawValue, items: data)
        }

        socket.on(clientEvent: .statusChange) { [weak self] data, _ in
            guard let self else { return }
            self.debugLog("client event statusChange payload=\(self.stringify(data))")
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
        debugLog("listener called event=\(eventName) payload=\(stringify(items))")
        notifyRawEvent(name: eventName, items: items)

        guard let event = makeRemoteCallStatusEvent(eventName: eventName, items: items) else { return }
        debugLog("listener parsed event=\(eventName) threadId=\(event.threadId) status=\(event.status.rawValue)")
        handlersByThreadID[event.threadId]?(event)
    }

    private func makeRemoteCallStatusEvent(eventName: String, items: [Any]) -> RemoteCallStatusEvent? {
        let payload = items.compactMap { $0 as? [String: Any] }.first
        let statusPayload = statusPayload(from: payload)
        let threadId = statusPayload?["thread_id"] as? String
            ?? statusPayload?["threadId"] as? String
            ?? payload?["thread_id"] as? String
            ?? payload?["threadId"] as? String
            ?? inferredThreadID(forEventName: eventName)
        let statusValue = rawStatusValue(fromPayload: payload)
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

    private func rawStatusValue(fromPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }

        if let nestedPayload = statusPayload(from: payload),
           let nestedStatus = rawStatusValue(fromPayload: nestedPayload) {
            return nestedStatus
        }

        let candidateKeys = ["status", "type", "data", "event", "name"]
        for key in candidateKeys {
            guard let rawValue = payload[key] else { continue }

            if let status = normalizedStatusValue(from: rawValue) {
                return status
            }
        }

        return nil
    }

    private func statusPayload(from payload: [String: Any]?) -> [String: Any]? {
        guard let payload else { return nil }

        if let nestedPayload = payload["data"] as? [String: Any] {
            return nestedPayload
        }

        return nil
    }

    private func normalizedStatusValue(from value: Any) -> String? {
        if let status = value as? CallStatus {
            return status.rawValue
        }

        if let string = value as? String {
            return CallStatus(rawValue: string) != nil ? string : nil
        }

        return nil
    }

    private func inferredThreadID(forEventName eventName: String) -> String? {
        if let channelNameProvider = configuration.statusChannelNameProvider {
            let matchingThreadIDs = handlersByThreadID.keys.filter { channelNameProvider($0) == eventName }
            if matchingThreadIDs.count == 1 {
                return matchingThreadIDs[0]
            }
        }

        if handlersByThreadID.count == 1 {
            return handlersByThreadID.keys.first
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

        emitEvent(subscribeEventName, payload: ["thread_id": threadId], context: "subscribe")
    }

    private func unsubscribeIfNeeded(threadId: String) {
        guard
            socket.status == .connected,
            let unsubscribeEventName = configuration.unsubscribeEventName,
            configuration.statusChannelNameProvider == nil
        else {
            return
        }

        emitEvent(unsubscribeEventName, payload: ["thread_id": threadId], context: "unsubscribe")
    }

    private func resubscribeAllThreads() {
        pendingSubscriptions.forEach(subscribeIfNeeded(threadId:))
    }

    private func flushPendingStatusPayloads() {
        guard socket.status == .connected else { return }
        let payloads = pendingStatusPayloads
        pendingStatusPayloads.removeAll()
        payloads.forEach { payload in
            emitEvent(configuration.statusEventName, payload: payload, context: "flush-pending")
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
        debugLog("attach status channel listener threadId=\(threadId) channel=\(channel)")
        socket.off(channel)
        socket.on(channel) { [weak self] data, _ in
            self?.handle(eventName: channel, items: data)
        }
    }

    private func removeStatusChannelListenerIfNeeded(threadId: String) {
        guard let channelNameProvider = configuration.statusChannelNameProvider else { return }
        let channel = channelNameProvider(threadId)
        debugLog("remove status channel listener threadId=\(threadId) channel=\(channel)")
        socket.off(channel)
    }

    private func removeDynamicListeners() {
        dynamicListeners.keys.forEach {
            debugLog("remove dynamic listener channel=\($0)")
            socket.off($0)
        }
        dynamicListeners.removeAll()
    }

    private func emitEvent(_ eventName: String, payload: [String: Any], context: String) {
        let sanitizedPayload = Self.sanitizedJSONObject(payload)
        debugLog("emit event=\(eventName) context=\(context) payload=\(stringify(sanitizedPayload))")
        socket.emit(eventName, sanitizedPayload)
    }

    private func debugLog(_ message: String) {
        print("[TevioCallModule.Socket] \(message)")
    }

    private func stringify(_ value: Any) -> String {
        let sanitizedValue = Self.sanitizedJSONValue(value, stringifyUnsupportedValues: true) ?? String(describing: value)
        if let data = try? JSONSerialization.data(withJSONObject: sanitizedValue, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        return String(describing: sanitizedValue)
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

    private static func sanitizedJSONObject(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [String: Any]()) { result, element in
            guard let sanitizedValue = sanitizedJSONValue(element.value, stringifyUnsupportedValues: true) else { return }
            result[element.key] = sanitizedValue
        }
    }

    private static func sanitizedJSONValue(_ value: Any, stringifyUnsupportedValues: Bool = false) -> Any? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let int8 as Int8:
            return Int(int8)
        case let int16 as Int16:
            return Int(int16)
        case let int32 as Int32:
            return Int(int32)
        case let int64 as Int64:
            return int64
        case let uint as UInt:
            return uint
        case let uint8 as UInt8:
            return UInt(uint8)
        case let uint16 as UInt16:
            return UInt(uint16)
        case let uint32 as UInt32:
            return UInt(uint32)
        case let uint64 as UInt64:
            return uint64
        case let double as Double:
            return double
        case let float as Float:
            return Double(float)
        case let decimal as Decimal:
            return NSDecimalNumber(decimal: decimal)
        case let url as URL:
            return url.absoluteString
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let array as [Any]:
            return array.compactMap { sanitizedJSONValue($0, stringifyUnsupportedValues: stringifyUnsupportedValues) }
        case let dictionary as [String: Any]:
            return sanitizedJSONObject(dictionary)
        case let dictionary as [AnyHashable: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, element in
                guard let key = element.key as? String,
                      let sanitizedValue = sanitizedJSONValue(element.value, stringifyUnsupportedValues: stringifyUnsupportedValues) else { return }
                result[key] = sanitizedValue
            }
        default:
            return stringifyUnsupportedValues ? String(describing: value) : nil
        }
    }
}
