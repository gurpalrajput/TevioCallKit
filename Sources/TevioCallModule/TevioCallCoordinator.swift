import AVFoundation
import Foundation
import SwiftUI
import UIKit

@MainActor
final class TevioCallCoordinator {
    private(set) var currentSession: CallSession? {
        didSet {
            if let currentSession {
                sessionStore.saveCurrentSession(currentSession)
            } else {
                sessionStore.clearCurrentSession()
            }
        }
    }

    private weak var transport: CallTransporting?
    private weak var backend: CallBackendProviding?
    private weak var host: CallHostCoordinating?
    private weak var callKitController: CallKitControlling?
    private let audioEngine: CallAudioEngining
    private let configuration: CallUIConfiguration
    private let sessionStore: CallSessionStoring
    private let logger: CallLogging
    private let presenter: TevioCallPresenter
    private let lifecycleObserver: TevioCallLifecycle

    private var unansweredTimer: DispatchWorkItem?
    private var elapsedTimer: Timer?
    private var pendingDismissWorkItem: DispatchWorkItem?
    private var lastPushHandledAt: TimeInterval = 0
    private let pushDebounceInterval: TimeInterval = 1
    private let terminalStatusDisplayDuration: TimeInterval = 2.5
    private let busyRetryInterval: TimeInterval = 0.6
    private let busyRetryCount = 3
    private let socketConnectionTimeout: TimeInterval = 4
    private var pendingEndStatus: CallStatus?
    private var incomingViewModel: IncomingCallViewModel?
    private var activeViewModel: ActiveCallViewModel?
    private var isAwaitingCallKitAnswerTransaction = false
    private var isAwaitingCallKitEndTransaction = false
    private var isFinalizing = false
    private var shouldJoinOnAudioActivation = false
    private let defaultMutedState = false
    private let defaultSpeakerEnabledState = false

    init(
        transport: CallTransporting,
        backend: CallBackendProviding,
        host: CallHostCoordinating,
        audioEngine: CallAudioEngining,
        configuration: CallUIConfiguration,
        sessionStore: CallSessionStoring,
        logger: CallLogging
    ) {
        self.transport = transport
        self.backend = backend
        self.host = host
        self.audioEngine = audioEngine
        self.configuration = configuration
        self.sessionStore = sessionStore
        self.logger = logger
        self.presenter = TevioCallPresenter(host: host, logger: logger)
        self.lifecycleObserver = TevioCallLifecycle()
        self.currentSession = sessionStore.loadCurrentSession()
        bindAudioCallbacks()
        bindLifecycle()
    }

    func setCallKitController(_ controller: CallKitControlling?) {
        callKitController = controller
    }

    func start() {
        lifecycleObserver.start()
        replayPendingEvents()
        synchronizePresentationForCurrentState()
    }

    func startOutgoingCall(request: OutgoingCallRequest) {
        guard currentSession == nil else {
            logger.log("State", message: "ignored outgoing call while another session exists", context: context())
            return
        }

        let initializingPayload = CallPayload.placeholderOutgoing(threadId: request.threadId)
        currentSession = CallSession(
            payload: initializingPayload,
            direction: .outgoing,
            state: .initializingOutgoing
        )
        logger.log("State", message: "starting outgoing initialization", context: context(threadId: request.threadId))

        guard let backend else {
            currentSession = nil
            return
        }

        backend.initiateOutgoingCall(threadId: request.threadId) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let payload):
                    self.beginOutgoingCall(with: payload)
                case .failure(let error):
                    self.logger.log("API", message: "outgoing initialization failed", context: self.context(threadId: request.threadId))
                    self.currentSession = nil
                    self.presenter.showError(
                        title: "Unable to Start Call",
                        message: error.localizedDescription.isEmpty ? "Unable to start the call. Please try again." : error.localizedDescription
                    )
                }
            }
        }
    }

    func handleIncomingPush(payload: [AnyHashable: Any], completion: @escaping () -> Void) {
        let now = Date().timeIntervalSince1970
        guard now - lastPushHandledAt >= pushDebounceInterval else {
            logger.log("PushKit", message: "debounced duplicate incoming push", context: context())
            completion()
            return
        }
        lastPushHandledAt = now

        let incomingThreadId = threadId(from: payload)

        if let directStatus = directTerminationStatus(from: payload) {
            if incomingThreadId == currentSession?.payload.threadId {
                handleRemoteTermination(status: directStatus, source: .pushKit)
            }
            completion()
            return
        }

        if let session = currentSession,
           session.state != .idle,
           session.state != .ended,
           session.state != .failed {
            if let incomingThreadId, incomingThreadId != session.payload.threadId {
                emitBusyStatus(for: incomingThreadId, whileActiveThreadIdIs: session.payload.threadId, completion: completion)
            } else {
                completion()
            }
            return
        }

        guard let payload = CallPayload(userInfo: payload) else {
            completion()
            return
        }

        presenter.prepareForIncomingCall()
        createIncomingSession(with: payload)
        reportIncomingCall(completion: completion)
    }

    func answerCall(source: CallActionSource) {
        guard let session = currentSession else { return }
        guard session.state == .ringing || session.state == .incomingReceived else { return }

        if source != .callKit,
           callKitController != nil,
           !isAwaitingCallKitAnswerTransaction {
            isAwaitingCallKitAnswerTransaction = true
            callKitController?.requestAnswer(callUUID: session.callUUID) { [weak self] success in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isAwaitingCallKitAnswerTransaction = false
                    if !success {
                        self.performAnsweredCallPipeline(fromCallKit: false, source: source)
                    }
                }
            }
            return
        }

        transitionCurrentSession(to: .answering)
        performAnsweredCallPipeline(fromCallKit: source == .callKit, source: source)
    }

    func declineCall(source: CallActionSource) {
        endCall(source: source, status: .declined)
    }

    func endCall(source: CallActionSource, status: CallStatus = .ended) {
        pendingEndStatus = status

        guard let session = currentSession else {
            return
        }

        if source != .callKit,
           callKitController != nil,
           !isAwaitingCallKitEndTransaction {
            isAwaitingCallKitEndTransaction = true
            callKitController?.requestEnd(callUUID: session.callUUID) { [weak self] success in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isAwaitingCallKitEndTransaction = false
                    if !success {
                        self.performLocalEnd(status: status, source: source, emitStatus: true)
                    }
                }
            }
            return
        }

        performLocalEnd(status: status, source: source, emitStatus: source != .socket && source != .backend && source != .system)
    }

    func handleRemoteStatus(_ event: RemoteCallStatusEvent) {
        guard event.threadId == currentSession?.payload.threadId else { return }
        switch event.status {
        case .visible:
            updateActiveCallStatus(text: configuration.ringingText)
        case .busy, .declined, .ended, .notAnswered:
            handleRemoteTermination(status: event.status, source: .socket)
        case .none:
            break
        }
    }

    func handleCallKitAnswerAction() -> Bool {
        guard let session = currentSession else { return false }
        guard session.state == .ringing || session.state == .incomingReceived || isAwaitingCallKitAnswerTransaction else {
            return false
        }
        answerCall(source: .callKit)
        return true
    }

    func handleCallKitEndAction() -> Bool {
        guard currentSession != nil else { return false }
        let status = pendingEndStatus ?? ((currentSession?.state == .ringing || currentSession?.state == .incomingReceived) ? .declined : .ended)
        endCall(source: .callKit, status: status)
        return true
    }

    func handleProviderDidReset() {
        performLocalEnd(status: .ended, source: .system, emitStatus: false)
    }

    func handleActivatedAudioSession(_ audioSession: AVAudioSession) {
        audioEngine.didActivateAudioSession(audioSession)
        if shouldJoinOnAudioActivation {
            shouldJoinOnAudioActivation = false
            audioEngine.joinChannel()
        }
    }

    func handleDeactivatedAudioSession(_ audioSession: AVAudioSession) {
        audioEngine.didDeactivateAudioSession(audioSession)
    }

    func handleApplicationDidBecomeActive() {
        synchronizePresentationForCurrentState()
        replayPendingEvents()
    }

    func handleApplicationDidEnterBackground() {
        presenter.handleDidEnterBackground()
    }

    private func bindLifecycle() {
        lifecycleObserver.onDidBecomeActive = { [weak self] in
            Task { @MainActor in
                self?.handleApplicationDidBecomeActive()
            }
        }
        lifecycleObserver.onDidEnterBackground = { [weak self] in
            Task { @MainActor in
                self?.handleApplicationDidEnterBackground()
            }
        }
    }

    private func beginOutgoingCall(with payload: CallPayload) {
        pendingDismissWorkItem?.cancel()
        stopListeningForCallStatus(session: currentSession)
        currentSession = CallSession(payload: payload, direction: .outgoing, state: .outgoingInitialized)
        fetchThreadDetailsIfNeeded(threadId: payload.threadId)
        transport?.connectIfNeeded()
        startListening(threadId: payload.threadId)
        audioEngine.configure(with: payload)
        audioEngine.joinChannel()
        presentActiveCall(fromCallKit: false)
        updateActiveCallStatus(text: payload.role == .caller ? configuration.ringingText : configuration.connectingText)
        transitionCurrentSession(to: .connecting)
    }

    private func createIncomingSession(with payload: CallPayload) {
        pendingDismissWorkItem?.cancel()
        stopElapsedTimer()
        stopListeningForCallStatus(session: currentSession)
        currentSession = CallSession(payload: payload, direction: .incoming, state: .incomingReceived)
        fetchThreadDetailsIfNeeded(threadId: payload.threadId)
        transport?.connectIfNeeded()
        startListening(threadId: payload.threadId)
    }

    private func reportIncomingCall(completion: @escaping () -> Void) {
        guard let session = currentSession else {
            completion()
            return
        }

        let reportCompletion: (Bool) -> Void = { [weak self] success in
            guard let self else {
                completion()
                return
            }
            if success {
                self.transitionCurrentSession(to: .ringing)
                self.startUnansweredTimer()
                self.transport?.emit(status: .visible, threadId: session.payload.threadId, completion: nil)
                self.synchronizePresentationForCurrentState()
            } else {
                self.currentSession = nil
            }
            completion()
        }

        if let callKitController {
            callKitController.reportIncomingCall(session: session, completion: reportCompletion)
        } else {
            reportCompletion(true)
        }
    }

    private func performAnsweredCallPipeline(fromCallKit: Bool, source: CallActionSource) {
        guard let payload = currentSession?.payload else { return }
        cancelUnansweredTimer()
        pendingEndStatus = nil
        stopRingtone()
        presenter.prepareForAnsweredCall()
        transport?.ensureConnected(timeout: socketConnectionTimeout) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.currentSession?.payload.threadId == payload.threadId else { return }
                self.audioEngine.configure(with: payload)
                self.transitionCurrentSession(to: .connecting)
                self.presentActiveCall(fromCallKit: fromCallKit)
                if !fromCallKit {
                    self.audioEngine.joinChannel()
                } else {
                    self.shouldJoinOnAudioActivation = true
                }
                self.logger.log(
                    "State",
                    message: "answered call",
                    context: self.context(source: source, threadId: payload.threadId, callUUID: self.currentSession?.callUUID)
                )
                self.updateActiveCallStatus(text: self.configuration.connectingText)
            }
        }
    }

    private func performLocalEnd(status: CallStatus, source: CallActionSource, emitStatus: Bool) {
        guard !isFinalizing else { return }
        guard currentSession != nil else { return }
        let shouldDelayDismiss = source == .socket || source == .backend
        finalizeCall(
            status: status,
            source: source,
            emitStatus: emitStatus,
            dismissAfter: shouldDelayDismiss ? terminalStatusDisplayDuration : 0
        )
    }

    private func handleRemoteTermination(status: CallStatus, source: CallActionSource) {
        pendingEndStatus = nil
        guard currentSession != nil else { return }
        finalizeCall(status: status, source: source, emitStatus: false, dismissAfter: terminalStatusDisplayDuration)
    }

    private func finalizeCall(status: CallStatus, source: CallActionSource, emitStatus: Bool, dismissAfter: TimeInterval = 0) {
        guard let endingSession = currentSession else { return }
        guard !isFinalizing else { return }
        isFinalizing = true
        pendingDismissWorkItem?.cancel()
        cancelUnansweredTimer()
        stopElapsedTimer()
        stopRingtone()
        shouldJoinOnAudioActivation = false
        transitionCurrentSession(to: status == .declined && endingSession.state != .active ? .declining : .ending)
        audioEngine.leaveChannel()

        if emitStatus {
            emitTerminalStatusOrPersist(status: status, session: endingSession)
        }

        stopListeningForCallStatus(session: endingSession)
        updateActiveCallStatus(text: message(for: status))
        callKitController?.reportCallEnded(callUUID: endingSession.callUUID, status: status)
        transitionCurrentSession(to: .ended)

        logger.log(
            "State",
            message: "finalizing call",
            context: context(source: source, threadId: endingSession.payload.threadId, callUUID: endingSession.callUUID, state: endingSession.state)
        )

        let cleanup = { [weak self] in
            guard let self else { return }
            self.currentSession = nil
            self.incomingViewModel = nil
            self.activeViewModel = nil
            self.presenter.dismissCallUI(animated: true)
            self.presenter.clearPendingPresentation()
            self.pendingEndStatus = nil
            self.isFinalizing = false
            self.isAwaitingCallKitAnswerTransaction = false
            self.isAwaitingCallKitEndTransaction = false
        }

        if dismissAfter > 0 {
            let workItem = DispatchWorkItem(block: cleanup)
            pendingDismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: workItem)
        } else {
            cleanup()
        }
    }

    private func emitTerminalStatusOrPersist(status: CallStatus, session: CallSession) {
        transport?.ensureConnected(timeout: socketConnectionTimeout) { [weak self] connected in
            guard let self else { return }
            DispatchQueue.main.async {
                if connected {
                    self.transport?.emit(status: status, threadId: session.payload.threadId, completion: nil)
                    if self.shouldClearRemoteStatus(after: status) {
                        self.transport?.emit(status: .none, threadId: session.payload.threadId, completion: nil)
                    }
                } else {
                    self.sessionStore.enqueuePendingEvent(
                        PendingCallEvent(
                            callUUID: session.callUUID,
                            threadID: session.payload.threadId,
                            status: status
                        )
                    )
                }
            }
        }
    }

    private func replayPendingEvents() {
        let pendingEvents = sessionStore.loadPendingEvents()
        guard !pendingEvents.isEmpty else { return }

        transport?.ensureConnected(timeout: socketConnectionTimeout) { [weak self] connected in
            guard let self, connected else { return }
            DispatchQueue.main.async {
                pendingEvents.forEach { event in
                    self.transport?.emit(status: event.status, threadId: event.threadID, completion: nil)
                    self.sessionStore.removePendingEvent(id: event.id)
                }
            }
        }
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

    private func startListening(threadId: String) {
        transport?.startListening(threadId: threadId) { [weak self] event in
            Task { @MainActor in
                self?.handleRemoteStatus(event)
            }
        }
    }

    private func stopListeningForCallStatus(session: CallSession?) {
        transport?.stopListening(threadId: session?.payload.threadId)
    }

    private func presentIncomingCall() {
        guard let session = currentSession else { return }
        let model = incomingViewModel ?? IncomingCallViewModel()
        model.onAccept = { [weak self] in
            self?.stopRingtone()
            self?.answerCall(source: .incomingScreen)
        }
        model.onDecline = { [weak self] in
            self?.stopRingtone()
            self?.declineCall(source: .incomingScreen)
        }
        model.update(session: session, configuration: configuration)
        incomingViewModel = model
        let controller = UIHostingController(rootView: IncomingCallView(model: model))
        controller.modalPresentationStyle = .fullScreen
        presenter.presentIncomingCall(controller, for: session)
        playRingtoneIfNeeded()
    }

    private func presentActiveCall(fromCallKit: Bool) {
        guard let session = currentSession else { return }
        let model = activeViewModel ?? ActiveCallViewModel()
        applyDefaultAudioState(to: model)
        model.onToggleMute = { [weak self, weak model] in
            guard let self, let model else { return }
            model.isMuted.toggle()
            self.audioEngine.setMuted(model.isMuted)
        }
        model.onToggleSpeaker = { [weak self, weak model] in
            guard let self, let model else { return }
            model.speakerEnabled.toggle()
            self.audioEngine.setSpeakerEnabled(model.speakerEnabled)
        }
        model.onEnd = { [weak self] in
            self?.endCall(source: .activeCallScreen, status: .ended)
        }
        model.update(session: session)
        activeViewModel = model
        let controller = UIHostingController(rootView: ActiveCallView(model: model))
        controller.modalPresentationStyle = .fullScreen
        presenter.presentActiveCall(controller, for: session, replacingIncoming: true)
        shouldJoinOnAudioActivation = fromCallKit
    }

    private func synchronizePresentationForCurrentState() {
        guard let session = currentSession else {
            presenter.clearPendingPresentation()
            return
        }

        switch session.state {
        case .incomingReceived, .ringing:
            if presenter.isAppInForeground {
                presentIncomingCall()
            } else {
                presenter.setPendingPresentation(.incoming, sessionID: session.callUUID)
            }
        case .answering, .connecting, .active:
            if presenter.isAppInForeground {
                presentActiveCall(fromCallKit: false)
            } else {
                presenter.setPendingPresentation(.active, sessionID: session.callUUID)
            }
        default:
            break
        }
    }

    private func transitionCurrentSession(to newState: CallSessionState) {
        guard var session = currentSession else { return }
        guard TevioCallStateMachine.canTransition(from: session.state, to: newState) else { return }
        let oldState = session.state
        session.state = newState
        if newState == .active {
            session.connectedAt = session.connectedAt ?? Date()
            session.startedAt = session.startedAt ?? Date()
        }
        if newState == .ended || newState == .failed {
            session.endedAt = Date()
        }
        currentSession = session
        logger.log(
            "State",
            message: "\(oldState.rawValue) -> \(newState.rawValue)",
            context: context(threadId: session.payload.threadId, callUUID: session.callUUID, state: newState)
        )
    }

    private func startUnansweredTimer() {
        cancelUnansweredTimer()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let session = self.currentSession else { return }
            guard session.state == .ringing else { return }
            self.pendingEndStatus = .notAnswered
            self.endCall(source: .system, status: .notAnswered)
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

    private func bindAudioCallbacks() {
        audioEngine.onRemoteUserJoined = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.currentSession != nil else { return }
                self.transitionCurrentSession(to: .active)
                self.startElapsedTimer()
                self.updateActiveCallStatus(text: "00:00")
            }
        }

        audioEngine.onRemoteUserLeft = { [weak self] in
            DispatchQueue.main.async {
                self?.handleRemoteTermination(status: .ended, source: .backend)
            }
        }

        audioEngine.onRemoteMuteChanged = { [weak self] isMuted in
            DispatchQueue.main.async {
                self?.activeViewModel?.updateRemoteMuted(isMuted)
            }
        }
    }

    private func applyDefaultAudioState(to model: ActiveCallViewModel? = nil) {
        model?.isMuted = defaultMutedState
        model?.speakerEnabled = defaultSpeakerEnabledState
        audioEngine.setMuted(defaultMutedState)
        audioEngine.setSpeakerEnabled(defaultSpeakerEnabledState)
    }

    private func updateActiveCallStatus(text: String) {
        activeViewModel?.updateStatus(text)
    }

    private func playRingtoneIfNeeded() {
        guard let url = configuration.ringtoneURL else { return }
        presenter.playRingtoneIfNeeded(url: url)
    }

    private func stopRingtone() {
        presenter.stopRingtone()
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

    private func context(
        source: CallActionSource? = nil,
        threadId: String? = nil,
        callUUID: UUID? = nil,
        state: CallSessionState? = nil
    ) -> [String: String] {
        var values: [String: String] = [:]
        if let source {
            values["source"] = source.rawValue
        }
        if let threadId {
            values["threadID"] = threadId
        }
        if let callUUID {
            values["callUUID"] = callUUID.uuidString
        }
        if let state {
            values["state"] = state.rawValue
        }
        return values
    }
}
