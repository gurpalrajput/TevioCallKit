import Foundation

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

public enum CallDirection: String, Codable, Equatable {
    case incoming
    case outgoing
}

public enum CallActionSource: String, Codable, Equatable {
    case callKit
    case incomingScreen
    case activeCallScreen
    case socket
    case backend
    case pushKit
    case system
}

enum PendingCallPresentation: String, Codable, Equatable {
    case incoming
    case active
}

public enum CallSessionState: String, Codable, Equatable {
    case idle
    case initializingOutgoing
    case outgoingInitialized
    case incomingReceived
    case ringing
    case answering
    case connecting
    case active
    case declining
    case ending
    case ended
    case failed
}

public struct CallPayload: Codable, Equatable {
    public let callUUIDString: String?
    public let type: String
    public let threadId: String
    public let uid: String
    public let agoraToken: String
    public let appId: String
    public let callerName: String
    public let role: CallRole
    public let callerID: String?
    public let receiverID: String?

    public init(
        callUUIDString: String? = nil,
        type: String,
        threadId: String,
        uid: String,
        agoraToken: String,
        appId: String,
        callerName: String,
        role: CallRole,
        callerID: String? = nil,
        receiverID: String? = nil
    ) {
        self.callUUIDString = callUUIDString
        self.type = type
        self.threadId = threadId
        self.uid = uid
        self.agoraToken = agoraToken
        self.appId = appId
        self.callerName = callerName
        self.role = role
        self.callerID = callerID
        self.receiverID = receiverID
    }

    public init?(userInfo: [AnyHashable: Any]) {
        let type = (userInfo["type"] as? String) ?? (userInfo["status"] as? String) ?? "AUDIO_CALL"
        guard
            let threadId = userInfo["thread_id"] as? String,
            let uid = userInfo["uid"] as? String,
            let agoraToken = (userInfo["agora_token"] as? String) ?? (userInfo["token"] as? String),
            let appId = userInfo["app_id"] as? String
        else {
            return nil
        }

        self.init(
            callUUIDString: (userInfo["call_uuid"] as? String) ?? (userInfo["callUUID"] as? String),
            type: type,
            threadId: threadId,
            uid: uid,
            agoraToken: agoraToken,
            appId: appId,
            callerName: (userInfo["caller_name"] as? String) ?? (userInfo["body"] as? String) ?? "Incoming Call",
            role: CallRole(rawRole: userInfo["role"] as? String),
            callerID: (userInfo["caller_id"] as? String) ?? (userInfo["callerId"] as? String),
            receiverID: (userInfo["receiver_id"] as? String) ?? (userInfo["receiverId"] as? String)
        )
    }

    var resolvedCallUUID: UUID {
        guard let callUUIDString, let uuid = UUID(uuidString: callUUIDString) else {
            return UUID()
        }
        return uuid
    }

    static func placeholderOutgoing(threadId: String) -> CallPayload {
        CallPayload(
            type: "AUDIO_CALL",
            threadId: threadId,
            uid: "",
            agoraToken: "",
            appId: "",
            callerName: "",
            role: .caller
        )
    }
}

public struct CallThreadDetails: Codable, Equatable {
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

public struct RemoteCallStatusEvent: Codable, Equatable {
    public let threadId: String
    public let status: CallStatus

    public init(threadId: String, status: CallStatus) {
        self.threadId = threadId
        self.status = status
    }
}

public struct CallSession: Codable, Equatable {
    public let callUUID: UUID
    public let payload: CallPayload
    public let direction: CallDirection
    public var details: CallThreadDetails?
    public var state: CallSessionState
    public var startedAt: Date?
    public var connectedAt: Date?
    public var endedAt: Date?
    public var elapsedSeconds: Int
    public var lastKnownStatus: CallStatus?

    public init(
        callUUID: UUID? = nil,
        payload: CallPayload,
        direction: CallDirection = .incoming,
        details: CallThreadDetails? = nil,
        state: CallSessionState = .idle,
        startedAt: Date? = nil,
        connectedAt: Date? = nil,
        endedAt: Date? = nil,
        elapsedSeconds: Int = 0,
        lastKnownStatus: CallStatus? = nil
    ) {
        self.callUUID = callUUID ?? payload.resolvedCallUUID
        self.payload = payload
        self.direction = direction
        self.details = details
        self.state = state
        self.startedAt = startedAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.elapsedSeconds = elapsedSeconds
        self.lastKnownStatus = lastKnownStatus
    }
}

public struct PendingCallEvent: Codable, Equatable, Identifiable {
    public let id: UUID
    public let callUUID: UUID
    public let threadID: String
    public let status: CallStatus
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        callUUID: UUID,
        threadID: String,
        status: CallStatus,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.callUUID = callUUID
        self.threadID = threadID
        self.status = status
        self.createdAt = createdAt
    }
}
