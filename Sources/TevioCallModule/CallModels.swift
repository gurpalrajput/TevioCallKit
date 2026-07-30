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
            type: type,
            threadId: threadId,
            uid: uid,
            agoraToken: agoraToken,
            appId: appId,
            callerName: (userInfo["caller_name"] as? String) ?? (userInfo["body"] as? String) ?? "Incoming Call",
            role: CallRole(rawRole: userInfo["role"] as? String)
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

public struct CallSession: Equatable {
    public let callUUID: UUID
    public let payload: CallPayload
    public var details: CallThreadDetails?
    public var state: CallSessionState
    public var startedAt: Date?
    public var elapsedSeconds: Int

    public init(
        callUUID: UUID = UUID(),
        payload: CallPayload,
        details: CallThreadDetails? = nil,
        state: CallSessionState = .idle,
        startedAt: Date? = nil,
        elapsedSeconds: Int = 0
    ) {
        self.callUUID = callUUID
        self.payload = payload
        self.details = details
        self.state = state
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
    }
}
