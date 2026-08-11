import AVFoundation
#if canImport(CallKit) && !targetEnvironment(macCatalyst)
import CallKit
#endif
import Foundation
#if canImport(PushKit) && !targetEnvironment(macCatalyst)
import PushKit
#endif
import SwiftUI
import UIKit

@MainActor
public final class CallManager: NSObject {
    public private(set) var currentSession: CallSession?

    private weak var transport: CallTransporting?
    private weak var backend: CallBackendProviding?
    private weak var host: CallHostCoordinating?
    private let audioEngine: CallAudioEngining
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
    private var unansweredTimer: DispatchWorkItem?
    private var elapsedTimer: Timer?
    private var pendingDismissWorkItem: DispatchWorkItem?
    private let terminalStatusDisplayDuration: TimeInterval = 2.5
    private let busyRetryInterval: TimeInterval = 0.6
    private let busyRetryCount = 3
    private var pendingEndStatus: CallStatus?
    private var incomingViewModel: IncomingCallViewModel?
    private var activeViewModel: ActiveCallViewModel?
    private weak var incomingCallController: UIViewController?
    private weak var activeCallController: UIViewController?
    private var audioPlayer: AVAudioPlayer?
    private var shouldJoinOnAudioActivation = false
    private let defaultMutedState = false
    private let defaultSpeakerEnabledState = false
    /// Tracks whether the native CallKit UI was suppressed for the current
    /// incoming call because the app was in the foreground. When `true`,
    /// answer/end actions bypass CXCallController and go directly through
    /// our custom call UI to avoid the iPad full-screen CallKit overlay.
    private var didSuppressCallKitUI = false

    public init(
        transport: CallTransporting,
        backend: CallBackendProviding,
        host: CallHostCoordinating,
        audioEngine: CallAudioEngining = NoopCallAudioEngine(),
        configuration: CallUIConfiguration
    ) {
        self.transport = transport
        self.backend = backend
        self.host = host
        self.audioEngine = audioEngine
        self.configuration = configuration
        super.init()
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        provider.setDelegate(self, queue: nil)
        #endif
        bindAudioCallbacks()
    }

    public func start() {
        #if canImport(PushKit) && !targetEnvironment(macCatalyst)
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        #endif
    }

    public func startOutgoingCall(request: OutgoingCallRequest) {
        guard let backend else { return }
        backend.initiateOutgoingCall(threadId: request.threadId) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let payload):
                    self.beginOutgoingCall(with: payload)
                case .failure:
                    self.finishCallUI()
                }
            }
        }
    }

    public func answerCurrentCall() {
        pendingEndStatus = nil
        guard let uuid = currentSession?.callUUID else { return }
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        if didSuppressCallKitUI || host?.isAppInForeground == true {
            // Foreground: bypass the CXAnswerCallAction round-trip to avoid
            // the iPad full-screen CallKit UI fighting with our custom UI.
            // Report the call as answered elsewhere so CallKit dismisses.
            provider.reportCall(with: uuid, endedAt: nil, reason: .answeredElsewhere)
            didSuppressCallKitUI = true
            handleAnsweredCall(fromCallKit: false)
        } else {
            // Background / lock-screen: use normal CallKit answer flow
            let action = CXAnswerCallAction(call: uuid)
            CXCallController().request(CXTransaction(action: action)) { _ in }
        }
        #else
        _ = uuid
        handleAnsweredCall(fromCallKit: false)
        #endif
    }

    public func declineCurrentCall() {
        endCurrentCall(status: .declined)
    }

    public func endCurrentCall(status: CallStatus = .ended) {
        pendingEndStatus = status
        guard let uuid = currentSession?.callUUID else {
            finalizeCall(status: status, emitStatus: true)
            return
        }
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        if didSuppressCallKitUI {
            // Foreground path: CallKit was already dismissed, finalize directly.
            finalizeCall(status: status, emitStatus: true)
        } else {
            let action = CXEndCallAction(call: uuid)
            CXCallController().request(CXTransaction(action: action)) { [weak self] error in
                guard let self, error != nil else { return }
                DispatchQueue.main.async {
                    self.finalizeCall(status: status, emitStatus: true)
                }
            }
        }
        #else
        _ = uuid
        finalizeCall(status: status, emitStatus: true)
        #endif
    }

    func setMuted(_ isMuted: Bool) {
        audioEngine.setMuted(isMuted)
    }

    func setSpeakerEnabled(_ isEnabled: Bool) {
        audioEngine.setSpeakerEnabled(isEnabled)
        
    }

    private func applyDefaultAudioState(to model: ActiveCallViewModel? = nil) {
        model?.isMuted = defaultMutedState
        model?.speakerEnabled = defaultSpeakerEnabledState
        setMuted(defaultMutedState)
        setSpeakerEnabled(defaultSpeakerEnabledState)
    }

    public func handleIncomingPush(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let incomingThreadId = threadId(from: payload)
        let incomingPayload = CallPayload(userInfo: payload)

        if let directStatus = directTerminationStatus(from: payload) {
            if incomingThreadId == currentSession?.payload.threadId {
                handleRemoteTermination(status: directStatus)
            }
            reportTransientIncomingCallIfNeeded(payload: incomingPayload, endStatus: directStatus, completion: completion)
            return
        }

        if let session = currentSession, session.state != .idle {
            if let incomingPayload, incomingPayload.threadId == session.payload.threadId {
                reportTransientIncomingCallIfNeeded(payload: incomingPayload, completion: completion)
                return
            }

            if let incomingThreadId, incomingThreadId != session.payload.threadId {
                emitBusyStatus(for: incomingThreadId, whileActiveThreadIdIs: session.payload.threadId, completion: {})
                reportTransientIncomingCallIfNeeded(payload: incomingPayload, endStatus: .busy, completion: completion)
            } else {
                reportTransientIncomingCallIfNeeded(payload: incomingPayload, markFailed: true, completion: completion)
            }
            return
        }

        guard let payload = incomingPayload else {
            reportTransientIncomingCallIfNeeded(payload: nil, markFailed: true, completion: completion)
            return
        }

        host?.prepareForIncomingCall()
        createIncomingSession(with: payload)
        reportIncomingCall(completion: completion)
    }

    private func beginOutgoingCall(with payload: CallPayload) {
        pendingDismissWorkItem?.cancel()
        stopListeningForCallStatus()
        currentSession = CallSession(payload: payload, state: .connecting)
        fetchThreadDetailsIfNeeded(threadId: payload.threadId)
        transport?.connectIfNeeded()
        transport?.startListening(threadId: payload.threadId) { [weak self] event in
            self?.handleRemoteStatus(event)
        }
        audioEngine.configure(with: payload)
        audioEngine.joinChannel()
        presentActiveCall(fromCallKit: false)
        updateActiveCallStatus(text: payload.role == .caller ? configuration.ringingText : configuration.connectingText)
    }

    private func createIncomingSession(with payload: CallPayload) {
        pendingDismissWorkItem?.cancel()
        stopElapsedTimer()
        stopListeningForCallStatus()
        currentSession = CallSession(payload: payload, state: .ringing)
        fetchThreadDetailsIfNeeded(threadId: payload.threadId)
        transport?.connectIfNeeded()
        transport?.startListening(threadId: payload.threadId) { [weak self] event in
            self?.handleRemoteStatus(event)
        }
    }

    private func reportIncomingCall(completion: @escaping () -> Void) {
        guard let session = currentSession else {
            completion()
            return
        }

        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        let update = CXCallUpdate()
        update.localizedCallerName = session.payload.callerName
        update.hasVideo = false

        provider.reportNewIncomingCall(with: session.callUUID, update: update) { [weak self] error in
            guard let self else {
                completion()
                return
            }
            DispatchQueue.main.async {
                if error == nil {
                    self.startUnansweredTimer()
                    self.transport?.emit(status: .visible, threadId: session.payload.threadId, completion: nil)
                    let isForeground = self.host?.isAppInForeground == true
                    if isForeground {
                        // Immediately suppress the native CallKit UI so it
                        // doesn't flash over our custom incoming call screen.
                        // On iPad this prevents the full-screen CallKit overlay.
                        self.provider.reportCall(
                            with: session.callUUID,
                            endedAt: nil,
                            reason: .answeredElsewhere
                        )
                        self.didSuppressCallKitUI = true
                        self.presentIncomingCall()
                    }
                }
                completion()
            }
        }
        #else
        startUnansweredTimer()
        transport?.emit(status: .visible, threadId: session.payload.threadId, completion: nil)
        if host?.isAppInForeground == true {
            presentIncomingCall()
        }
        completion()
        #endif
    }

    private func reportTransientIncomingCallIfNeeded(
        payload: CallPayload?,
        endStatus: CallStatus? = nil,
        markFailed: Bool = false,
        completion: @escaping () -> Void
    ) {
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        let update = CXCallUpdate()
        update.localizedCallerName = payload?.callerName ?? configuration.appName
        update.hasVideo = false

        let callUUID = UUID()
        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else {
                    completion()
                    return
                }

                if markFailed {
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
                } else if let endStatus {
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: self.callEndedReason(for: endStatus))
                }
                completion()
            }
        }
        #else
        _ = payload
        _ = endStatus
        _ = markFailed
        completion()
        #endif
    }

    private func presentIncomingCall() {
        guard let session = currentSession else { return }
        let model = incomingViewModel ?? IncomingCallViewModel()
        model.onAccept = { [weak self] in
            self?.stopRingtone()
            self?.answerCurrentCall()
        }
        model.onDecline = { [weak self] in
            self?.stopRingtone()
            self?.declineCurrentCall()
        }
        model.update(session: session, configuration: configuration)
        incomingViewModel = model
        let controller = UIHostingController(rootView: IncomingCallView(model: model))
        controller.modalPresentationStyle = .fullScreen
        incomingCallController = controller
        host?.presentIncomingCall(controller)
        playRingtoneIfNeeded()
    }

    private func presentActiveCall(fromCallKit: Bool) {
        guard let session = currentSession else { return }
        let model = activeViewModel ?? ActiveCallViewModel()
        applyDefaultAudioState(to: model)
        model.onToggleMute = { [weak self, weak model] in
            guard let self, let model else { return }
            model.isMuted.toggle()
            self.setMuted(model.isMuted)
        }
        model.onToggleSpeaker = { [weak self, weak model] in
            guard let self, let model else { return }
            model.speakerEnabled.toggle()
            self.setSpeakerEnabled(model.speakerEnabled)
        }
        model.onEnd = { [weak self] in
            self?.endCurrentCall()
        }
        model.update(session: session)
        activeViewModel = model
        let controller = UIHostingController(rootView: ActiveCallView(model: model))
        controller.modalPresentationStyle = .fullScreen
        activeCallController = controller
        shouldJoinOnAudioActivation = fromCallKit

        if let incomingController = incomingCallController,
           let presenter = incomingController.presentingViewController {
            incomingController.dismiss(animated: false) { [weak self] in
                guard let self else { return }
                self.incomingCallController = nil
                presenter.present(controller, animated: true)
            }
            return
        }

        host?.presentActiveCall(controller)
    }

    private func fetchThreadDetailsIfNeeded(threadId: String) {
        guard let backend else { return }
        backend.fetchThreadDetails(threadId: threadId) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                guard var session = self.currentSession, session.payload.threadId == threadId else { return }
                if case .success(let details) = result {
                    session.details = details
                    self.currentSession = session
                    self.incomingViewModel?.update(session: session, configuration: self.configuration)
                    self.activeViewModel?.update(session: session)
                }
            }
        }
    }

    private func handleAnsweredCall(fromCallKit: Bool) {
        guard var session = currentSession else { return }
        cancelUnansweredTimer()
        pendingEndStatus = nil
        stopRingtone()
        host?.prepareForAnsweredCall()
        transport?.connectIfNeeded()
        audioEngine.configure(with: session.payload)
        session.state = .connecting
        currentSession = session
        presentActiveCall(fromCallKit: fromCallKit)
        if !fromCallKit {
            audioEngine.joinChannel()
        }
        updateActiveCallStatus(text: configuration.connectingText)
    }

    private func handleRemoteStatus(_ event: RemoteCallStatusEvent) {
        guard event.threadId == currentSession?.payload.threadId else { return }
        switch event.status {
        case .visible:
            updateActiveCallStatus(text: configuration.ringingText)
        case .busy:
            handleRemoteTermination(status: .busy)
        case .declined:
            handleRemoteTermination(status: .declined)
        case .ended:
            handleRemoteTermination(status: .ended)
        case .notAnswered:
            handleRemoteTermination(status: .notAnswered)
        case .none:
            break
        }
    }

    private func handleRemoteTermination(status: CallStatus) {
        pendingEndStatus = nil
        guard currentSession != nil else { return }
        finalizeCall(status: status, emitStatus: false, dismissAfter: terminalStatusDisplayDuration)
    }

    private func finalizeCall(status: CallStatus, emitStatus: Bool, dismissAfter: TimeInterval = 0) {
        let callUUID = currentSession?.callUUID
        pendingDismissWorkItem?.cancel()
        cancelUnansweredTimer()
        stopElapsedTimer()
        audioEngine.leaveChannel()

        if emitStatus, let threadId = currentSession?.payload.threadId {
            transport?.emit(status: status, threadId: threadId, completion: nil)
            if shouldClearRemoteStatus(after: status) {
                transport?.emit(status: .none, threadId: threadId, completion: nil)
            }
        }

        stopListeningForCallStatus()
        updateActiveCallStatus(text: message(for: status))
        stopRingtone()
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        if let callUUID {
            provider.reportCall(with: callUUID, endedAt: Date(), reason: callEndedReason(for: status))
        }
        #endif
        if dismissAfter > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                self?.resetCallPresentationState(animated: true)
            }
            pendingDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: workItem)
            return
        }

        resetCallPresentationState(animated: true)
    }

    private func finishCallUI() {
        pendingDismissWorkItem?.cancel()
        cancelUnansweredTimer()
        stopElapsedTimer()
        dismissPresentedCallUI(animated: true)
    }

    private func resetCallPresentationState(animated: Bool) {
        pendingDismissWorkItem?.cancel()
        pendingDismissWorkItem = nil
        dismissPresentedCallUI(animated: animated)
        currentSession = nil
        activeViewModel = nil
        incomingViewModel = nil
        activeCallController = nil
        incomingCallController = nil
        pendingEndStatus = nil
        didSuppressCallKitUI = false
    }

    private func dismissPresentedCallUI(animated: Bool) {
        if let incomingController = incomingCallController,
           incomingController.presentingViewController != nil {
            incomingController.dismiss(animated: animated)
            return
        }

        if let activeController = activeCallController,
           activeController.presentingViewController != nil {
            activeController.dismiss(animated: animated)
            return
        }

        host?.dismissCallUI(animated: animated)
    }

    private func startUnansweredTimer() {
        cancelUnansweredTimer()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let session = self.currentSession else { return }
            guard session.state == .ringing else { return }
            self.pendingEndStatus = .notAnswered
            self.endCurrentCall(status: .notAnswered)
        }
        unansweredTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: workItem)
    }

    private func cancelUnansweredTimer() {
        unansweredTimer?.cancel()
        unansweredTimer = nil
    }

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, var session = self.currentSession else { return }
            session.elapsedSeconds += 1
            self.currentSession = session
            self.activeViewModel?.updateDuration(seconds: session.elapsedSeconds)
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    private func stopListeningForCallStatus() {
        transport?.stopListening(threadId: currentSession?.payload.threadId)
    }

    private func bindAudioCallbacks() {
        audioEngine.onRemoteUserJoined = { [weak self] in
            guard let self, var session = self.currentSession else { return }
            DispatchQueue.main.async {
                session.state = .active
                session.startedAt = Date()
                self.currentSession = session
                self.startElapsedTimer()
                self.updateActiveCallStatus(text: "00:00")
            }
        }

        audioEngine.onRemoteUserLeft = { [weak self] in
            DispatchQueue.main.async {
                self?.handleRemoteTermination(status: .ended)
            }
        }

        audioEngine.onRemoteMuteChanged = { [weak self] isMuted in
            DispatchQueue.main.async {
                self?.activeViewModel?.updateRemoteMuted(isMuted)
            }
        }
    }

    private func updateActiveCallStatus(text: String) {
        activeViewModel?.updateStatus(text)
    }

    private func playRingtoneIfNeeded() {
        guard let url = configuration.ringtoneURL else { return }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.play()
        } catch {
            audioPlayer = nil
        }
    }

    private func stopRingtone() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func message(for status: CallStatus) -> String {
        switch status {
        case .busy:
            return configuration.busyText
        case .declined, .ended:
            return configuration.callEndedText
        case .notAnswered:
            return configuration.notAnsweredText
        case .visible:
            return configuration.incomingText
        case .none:
            return configuration.callEndedText
        }
    }

    private func directTerminationStatus(from payload: [AnyHashable: Any]) -> CallStatus? {
        let rawStatus = (payload["status"] as? String) ?? (payload["type"] as? String)
        guard let rawStatus else { return nil }
        switch rawStatus {
        case CallStatus.ended.rawValue:
            return .ended
        case CallStatus.declined.rawValue:
            return .declined
        case CallStatus.notAnswered.rawValue:
            return .notAnswered
        case CallStatus.busy.rawValue:
            return .busy
        default:
            return nil
        }
    }

    private func threadId(from payload: [AnyHashable: Any]) -> String? {
        (payload["thread_id"] as? String) ?? (payload["threadId"] as? String)
    }

    private func emitBusyStatus(
        for threadId: String,
        whileActiveThreadIdIs activeThreadId: String,
        completion: @escaping () -> Void
    ) {
        transport?.emit(status: .busy, threadId: threadId, completion: completion)

        guard busyRetryCount > 1 else { return }

        for attempt in 1..<busyRetryCount {
            let deadline = DispatchTime.now() + (busyRetryInterval * Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
                guard
                    let self,
                    self.currentSession?.payload.threadId == activeThreadId
                else {
                    return
                }

                self.transport?.emit(status: .busy, threadId: threadId, completion: nil)
            }
        }
    }

    private func shouldClearRemoteStatus(after status: CallStatus) -> Bool {
        switch status {
        case .busy, .declined, .ended, .notAnswered:
            return true
        case .none, .visible:
            return false
        }
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
        finalizeCall(status: .ended, emitStatus: false)
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Only process if the call is still in ringing state.
        // If the call was already answered via the foreground path,
        // currentSession will be in .connecting or .active state.
        if currentSession?.state == .ringing {
            handleAnsweredCall(fromCallKit: true)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Only process if there's still an active session that hasn't been finalized.
        if currentSession != nil, !didSuppressCallKitUI {
            let status = pendingEndStatus ?? ((currentSession?.state == .ringing) ? .declined : .ended)
            finalizeCall(status: status, emitStatus: pendingEndStatus != nil || status == .declined)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioEngine.didActivateAudioSession(audioSession)
        if shouldJoinOnAudioActivation {
            shouldJoinOnAudioActivation = false
            audioEngine.joinChannel()
        }
    }

    private func callEndedReason(for status: CallStatus) -> CXCallEndedReason {
        switch status {
        case .busy, .declined:
            return .remoteEnded
        case .ended:
            return .remoteEnded
        case .notAnswered:
            return .unanswered
        case .none, .visible:
            return .failed
        }
    }
}
#endif
