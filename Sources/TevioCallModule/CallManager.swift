import AVFoundation
#if canImport(CallKit) && !targetEnvironment(macCatalyst)
import CallKit
#endif
import Foundation
#if canImport(PushKit) && !targetEnvironment(macCatalyst)
import PushKit
#endif

@MainActor
public final class CallManager: NSObject {
    public var currentSession: CallSession? {
        coordinator.currentSession
    }

    private weak var host: CallHostCoordinating?
    private let coordinator: TevioCallCoordinator
    private let configuration: CallUIConfiguration

#if canImport(CallKit) && !targetEnvironment(macCatalyst)
    private lazy var provider: CXProvider = {
        let providerConfiguration = CXProviderConfiguration(localizedName: configuration.appName)
        providerConfiguration.supportsVideo = false
        providerConfiguration.includesCallsInRecents = true
        return CXProvider(configuration: providerConfiguration)
    }()
#endif

#if canImport(PushKit) && !targetEnvironment(macCatalyst)
    private var registry: PKPushRegistry?
#endif

    public init(
        transport: CallTransporting,
        backend: CallBackendProviding,
        host: CallHostCoordinating,
        audioEngine: CallAudioEngining = NoopCallAudioEngine(),
        configuration: CallUIConfiguration
    ) {
        self.host = host
        self.configuration = configuration
        let logger = DefaultCallLogger()
        let sessionStore = UserDefaultsCallSessionStore()
        self.coordinator = TevioCallCoordinator(
            transport: transport,
            backend: backend,
            host: host,
            audioEngine: audioEngine,
            configuration: configuration,
            sessionStore: sessionStore,
            logger: logger
        )
        super.init()
        coordinator.setCallKitController(self)
#if canImport(CallKit) && !targetEnvironment(macCatalyst)
        provider.setDelegate(self, queue: nil)
#endif
    }

    public func start() {
        coordinator.start()
#if canImport(PushKit) && !targetEnvironment(macCatalyst)
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
#endif
    }

    public func startOutgoingCall(request: OutgoingCallRequest) {
        coordinator.startOutgoingCall(request: request)
    }

    public func answerCurrentCall() {
        coordinator.answerCall(source: .incomingScreen)
    }

    public func declineCurrentCall() {
        coordinator.declineCall(source: .incomingScreen)
    }

    public func endCurrentCall(status: CallStatus = .ended) {
        coordinator.endCall(source: .activeCallScreen, status: status)
    }

    public func handleIncomingPush(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        coordinator.handleIncomingPush(payload: payload, completion: completion)
    }

    public func applicationDidBecomeActive() {
        coordinator.handleApplicationDidBecomeActive()
    }

    public func applicationDidEnterBackground() {
        coordinator.handleApplicationDidEnterBackground()
    }
}

#if canImport(PushKit) && !targetEnvironment(macCatalyst)
extension CallManager: PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        host?.didUpdateVoIPToken(token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        handleIncomingPush(payload: payload.dictionaryPayload, completion: completion)
    }
}
#endif

#if canImport(CallKit) && !targetEnvironment(macCatalyst)
extension CallManager: CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        coordinator.handleProviderDidReset()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if coordinator.handleCallKitAnswerAction() {
            action.fulfill()
        } else {
            action.fail()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if coordinator.handleCallKitEndAction() {
            action.fulfill()
        } else {
            action.fail()
        }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        coordinator.handleActivatedAudioSession(audioSession)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        coordinator.handleDeactivatedAudioSession(audioSession)
    }
}

extension CallManager: CallKitControlling {
    func requestAnswer(callUUID: UUID, completion: @escaping (Bool) -> Void) {
        let action = CXAnswerCallAction(call: callUUID)
        CXCallController().request(CXTransaction(action: action)) { error in
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    func requestEnd(callUUID: UUID, completion: @escaping (Bool) -> Void) {
        let action = CXEndCallAction(call: callUUID)
        CXCallController().request(CXTransaction(action: action)) { error in
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    func reportIncomingCall(session: CallSession, completion: @escaping (Bool) -> Void) {
        let update = CXCallUpdate()
        update.localizedCallerName = session.payload.callerName
        update.hasVideo = false
        provider.reportNewIncomingCall(with: session.callUUID, update: update) { error in
            DispatchQueue.main.async {
                completion(error == nil)
            }
        }
    }

    func reportCallEnded(callUUID: UUID, status: CallStatus) {
        provider.reportCall(with: callUUID, endedAt: Date(), reason: callEndedReason(for: status))
    }

    private func callEndedReason(for status: CallStatus) -> CXCallEndedReason {
        switch status {
        case .busy, .declined, .ended:
            return .remoteEnded
        case .notAnswered:
            return .unanswered
        case .none, .visible:
            return .failed
        }
    }
}
#endif
