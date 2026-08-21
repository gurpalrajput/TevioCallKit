import Foundation

enum CallPushPayloadSource: String {
    case topLevel = "top-level"
    case data = "data"
    case apsPayload = "aps.payload"
}

struct CallPushFieldMatch {
    let value: String
    let source: CallPushPayloadSource
}

public enum CallPushTransport: String, Codable {
    case voip = "voip"
    case remoteNotification = "remote_notification"
}

enum CallPushPayloadParser {
    private static let candidatePayloadSources: [CallPushPayloadSource] = [.topLevel, .data, .apsPayload]

    static func dictionary(for source: CallPushPayloadSource, in userInfo: [AnyHashable: Any]) -> [String: Any]? {
        switch source {
        case .topLevel:
            return sanitizedDictionary(userInfo)
        case .data:
            return nestedDictionary(forKeys: ["data"], in: userInfo)
        case .apsPayload:
            return nestedDictionary(forKeys: ["aps", "payload"], in: userInfo)
        }
    }

    static func stringValue(forKeys keys: [String], in userInfo: [AnyHashable: Any]) -> CallPushFieldMatch? {
        for source in candidatePayloadSources {
            guard let payload = dictionary(for: source, in: userInfo) else { continue }
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty {
                    return CallPushFieldMatch(value: value, source: source)
                }
            }
        }
        return nil
    }

    static func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    static func normalizedIncomingCallEventName(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }

        let normalizedValue = normalizedToken(rawValue)
        let collapsedValue = normalizedValue.replacingOccurrences(of: "-", with: "")
        switch collapsedValue {
        case "audiocall":
            return "incoming-audio-call"
        case "videocall":
            return "incoming-video-call"
        default:
            return nil
        }
    }

    private static func nestedDictionary(forKeys keys: [String], in userInfo: [AnyHashable: Any]) -> [String: Any]? {
        var current: Any? = userInfo
        for key in keys {
            if let hashableDictionary = current as? [AnyHashable: Any] {
                current = hashableDictionary[key]
            } else if let stringDictionary = current as? [String: Any] {
                current = stringDictionary[key]
            } else {
                current = nil
            }
        }

        if let hashableDictionary = current as? [AnyHashable: Any] {
            return sanitizedDictionary(hashableDictionary)
        }
        if let stringDictionary = current as? [String: Any] {
            return stringDictionary
        }
        return nil
    }

    private static func sanitizedDictionary(_ dictionary: [AnyHashable: Any]) -> [String: Any] {
        dictionary.reduce(into: [String: Any]()) { result, element in
            guard let key = element.key as? String else { return }
            result[key] = element.value
        }
    }
}

public enum CallStatus: String, Codable, CaseIterable {
    case none = "call-no-status"
    case visible = "call-visible"
    case notAnswered = "call-not-answered"
    case declined = "call-declined"
    case ended = "call-ended"
    case busy = "call-busy"
}

public enum CallRole: String, Codable {
    case caller
    case receiver
    case unknown

    public init(rawRole: String?) {
        self = CallRole(rawValue: rawRole ?? "") ?? .unknown
    }
}

public enum CallSessionState: Equatable {
    case idle
    case ringing
    case connecting
    case active
    case ending(CallStatus?)
}

public struct CallPayload: Codable, Equatable {
    public let type: String
    public let threadId: String
    public let uid: String
    public let agoraToken: String
    public let appId: String
    public let callerName: String
    public let role: CallRole

    public init(
        type: String,
        threadId: String,
        uid: String,
        agoraToken: String,
        appId: String,
        callerName: String,
        role: CallRole
    ) {
        self.type = type
        self.threadId = threadId
        self.uid = uid
        self.agoraToken = agoraToken
        self.appId = appId
        self.callerName = callerName
        self.role = role
    }

    public init?(userInfo: [AnyHashable: Any]) {
        self.init(voipUserInfo: userInfo)
    }

    init?(voipUserInfo userInfo: [AnyHashable: Any]) {
        let type = CallPushPayloadParser.stringValue(forKeys: ["type", "status"], in: userInfo)?.value ?? "AUDIO_CALL"
        guard
            let threadId = CallPushPayloadParser.stringValue(forKeys: ["thread_id", "threadId"], in: userInfo)?.value,
            let uid = CallPushPayloadParser.stringValue(forKeys: ["uid"], in: userInfo)?.value,
            let agoraToken = CallPushPayloadParser.stringValue(forKeys: ["agora_token", "token"], in: userInfo)?.value,
            let appId = CallPushPayloadParser.stringValue(forKeys: ["app_id"], in: userInfo)?.value
        else {
            return nil
        }

        self.init(
            type: type,
            threadId: threadId,
            uid: uid,
            agoraToken: agoraToken,
            appId: appId,
            callerName: CallPushPayloadParser.stringValue(forKeys: ["caller_name", "body"], in: userInfo)?.value ?? "Incoming Call",
            role: CallRole(rawRole: CallPushPayloadParser.stringValue(forKeys: ["role"], in: userInfo)?.value)
        )
    }
}

public struct CallThreadDetails: Equatable {
    public let name: String
    public let roleDescription: String
    public let imageURL: URL?

    public init(name: String, roleDescription: String, imageURL: URL? = nil) {
        self.name = name
        self.roleDescription = roleDescription
        self.imageURL = imageURL
    }
}

public struct OutgoingCallRequest: Equatable {
    public let threadId: String

    public init(threadId: String) {
        self.threadId = threadId
    }
}

public struct RemoteCallStatusEvent: Equatable {
    public let threadId: String
    public let status: CallStatus

    public init(threadId: String, status: CallStatus) {
        self.threadId = threadId
        self.status = status
    }
}

public enum IncomingCallPresentationMode: Equatable {
    case callKit
    case inApp
}

public struct CallSession: Equatable {
    public let callUUID: UUID
    public let payload: CallPayload
    public var details: CallThreadDetails?
    public var state: CallSessionState
    public var startedAt: Date?
    public var elapsedSeconds: Int
    public var incomingPresentationMode: IncomingCallPresentationMode
    public var hasReportedIncomingCallToSystem: Bool
    public var hasPresentedIncomingCallUI: Bool

    public init(
        callUUID: UUID = UUID(),
        payload: CallPayload,
        details: CallThreadDetails? = nil,
        state: CallSessionState = .idle,
        startedAt: Date? = nil,
        elapsedSeconds: Int = 0,
        incomingPresentationMode: IncomingCallPresentationMode = .callKit,
        hasReportedIncomingCallToSystem: Bool = false,
        hasPresentedIncomingCallUI: Bool = false
    ) {
        self.callUUID = callUUID
        self.payload = payload
        self.details = details
        self.state = state
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.incomingPresentationMode = incomingPresentationMode
        self.hasReportedIncomingCallToSystem = hasReportedIncomingCallToSystem
        self.hasPresentedIncomingCallUI = hasPresentedIncomingCallUI
    }
}
