import AVFoundation
import Foundation
import UIKit

public struct CallAudioRouteState: Equatable {
    public enum Route: Equatable {
        case receiver
        case speaker
        case bluetooth(name: String)
    }

    public let currentRoute: Route
    public let availableRoutes: [Route]

    public init(currentRoute: Route, availableRoutes: [Route]) {
        self.currentRoute = currentRoute
        self.availableRoutes = availableRoutes
    }
}

public protocol CallTransporting: AnyObject {
    func connectIfNeeded()
    func emit(status: CallStatus, threadId: String, completion: (() -> Void)?)
    func startListening(threadId: String, handler: @escaping (RemoteCallStatusEvent) -> Void)
    func stopListening(threadId: String?)
}

public protocol CallBackendProviding: AnyObject {
    func initiateOutgoingCall(threadId: String, completion: @escaping (Result<CallPayload, Error>) -> Void)
    func fetchThreadDetails(threadId: String, completion: @escaping (Result<CallThreadDetails, Error>) -> Void)
}

public protocol CallHostCoordinating: AnyObject {
    var isAppInForeground: Bool { get }
    func prepareForIncomingCall()
    func prepareForAnsweredCall()
    func presentIncomingCall(_ viewController: UIViewController)
    func presentActiveCall(_ viewController: UIViewController)
    func dismissCallUI(animated: Bool)
    func didUpdateVoIPToken(_ token: String)
}

public protocol CallAudioEngining: AnyObject {
    var onRemoteUserJoined: (() -> Void)? { get set }
    var onRemoteUserLeft: (() -> Void)? { get set }
    var onRemoteMuteChanged: ((Bool) -> Void)? { get set }
    var onAudioRouteChanged: ((CallAudioRouteState) -> Void)? { get set }
    func configure(with payload: CallPayload)
    func joinChannel()
    func leaveChannel()
    func setMuted(_ isMuted: Bool)
    func setSpeakerEnabled(_ isEnabled: Bool)
    func currentAudioRouteState() -> CallAudioRouteState
    func selectAudioRoute(_ route: CallAudioRouteState.Route)
    func didActivateAudioSession(_ audioSession: AVAudioSession)
}

public final class NoopCallAudioEngine: CallAudioEngining {
    public var onRemoteUserJoined: (() -> Void)?
    public var onRemoteUserLeft: (() -> Void)?
    public var onRemoteMuteChanged: ((Bool) -> Void)?
    public var onAudioRouteChanged: ((CallAudioRouteState) -> Void)?

    public init() {}

    public func configure(with payload: CallPayload) {}
    public func joinChannel() {
        onRemoteUserJoined?()
    }
    public func leaveChannel() {}
    public func setMuted(_ isMuted: Bool) {}
    public func setSpeakerEnabled(_ isEnabled: Bool) {}
    public func currentAudioRouteState() -> CallAudioRouteState {
        CallAudioRouteState(currentRoute: .receiver, availableRoutes: [.receiver, .speaker])
    }
    public func selectAudioRoute(_ route: CallAudioRouteState.Route) {
        onAudioRouteChanged?(CallAudioRouteState(currentRoute: route, availableRoutes: [.receiver, .speaker]))
    }
    public func didActivateAudioSession(_ audioSession: AVAudioSession) {}
}

public struct CallUIConfiguration {
    public let appName: String
    public let ringingText: String
    public let incomingText: String
    public let connectingText: String
    public let callEndedText: String
    public let notAnsweredText: String
    public let busyText: String
    public let ringtoneURL: URL?

    public init(
        appName: String,
        ringingText: String = "Ringing...",
        incomingText: String = "Incoming Call...",
        connectingText: String = "Connecting...",
        callEndedText: String = "Call ended",
        notAnsweredText: String = "Call not answered",
        busyText: String = "Busy on another call",
        ringtoneURL: URL? = nil
    ) {
        self.appName = appName
        self.ringingText = ringingText
        self.incomingText = incomingText
        self.connectingText = connectingText
        self.callEndedText = callEndedText
        self.notAnsweredText = notAnsweredText
        self.busyText = busyText
        self.ringtoneURL = ringtoneURL
    }
}
