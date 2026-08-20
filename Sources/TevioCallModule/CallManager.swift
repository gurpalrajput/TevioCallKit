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
    private enum PendingCallUIPresentation: Equatable {
        case incoming
        case active(fromCallKit: Bool)
    }

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
    private let duplicatePushSuppressionWindow: TimeInterval = 5
    private var pendingEndStatus: CallStatus?
    private var incomingViewModel: IncomingCallViewModel?
    private var activeViewModel: ActiveCallViewModel?
    private weak var incomingCallController: UIViewController?
    private weak var activeCallController: UIViewController?
    private var audioPlayer: AVAudioPlayer?
    private var shouldJoinOnAudioActivation = false
    private var hasStartedJoiningCurrentCall = false
    private var joinChannelFallbackWorkItem: DispatchWorkItem?
    #if canImport(CallKit) && !targetEnvironment(macCatalyst)
    private var pendingAnswerActionTimeoutWorkItem: DispatchWorkItem?
    #endif
    private let defaultMutedState = false
    private let defaultSpeakerEnabledState = false
    private let lifecycleBackgroundTaskDuration: TimeInterval = 5
    private let joinChannelFallbackDelay: TimeInterval = 1.5
    private let answerActionFulfillmentTimeout: TimeInterval = 3
    /// Tracks whether the native CallKit UI was suppressed for the current
    /// incoming call because the app was in the foreground. When `true`,
    /// answer/end actions bypass CXCallController and go directly through
    /// our custom call UI to avoid the iPad full-screen CallKit overlay.
    private var didSuppressCallKitUI = false
    private var pendingCallUIPresentation: PendingCallUIPresentation?
    private var recentPushEventTimestamps: [String: Date] = [:]
    #if canImport(CallKit) && !targetEnvironment(macCatalyst)
    private var pendingAnswerAction: CXAnswerCallAction?
    #endif

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

    public func notifyCallUIHostDidBecomeReady() {
        print("☎️ [CallManager] notifyCallUIHostDidBecomeReady — hostReady: \(host?.isCallUIHostReady ?? false), pendingUI: \(String(describing: pendingCallUIPresentation))")
        processPendingCallUIPresentationIfPossible()
    }

    public func startOutgoingCall(request: OutgoingCallRequest) {
        guard let backend else { return }
        backend.initiateOutgoingCall(threadId: request.threadId) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let payload):
                    self.beginOutgoingCall(with: payload)
                case .failure(let error):
                    self.finishCallUI()
                    self.host?.presentError(message: error.localizedDescription)
                }
            }
        }
    }

    public func answerCurrentCall() {
        pendingEndStatus = nil
        guard let uuid = currentSession?.callUUID else {
            print("☎️ [CallManager] answerCurrentCall — no session UUID, ignoring")
            return
        }
        print("☎️ [CallManager] answerCurrentCall — UUID: \(uuid), didSuppressCallKitUI: \(didSuppressCallKitUI), isForeground: \(host?.isAppInForeground ?? false)")
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        if didSuppressCallKitUI || host?.isAppInForeground == true {
            // Foreground: bypass the CXAnswerCallAction round-trip to avoid
            // the iPad full-screen CallKit UI fighting with our custom UI.
            print("☎️ [CallManager] answerCurrentCall — foreground path, bypassing CXAnswerCallAction")
            didSuppressCallKitUI = true
            handleAnsweredCall(fromCallKit: false)
        } else {
            // Background / lock-screen: use normal CallKit answer flow
            print("☎️ [CallManager] answerCurrentCall — background path, using CXAnswerCallAction")
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
        print("☎️ [CallManager] endCurrentCall — status: \(status.rawValue), didSuppressCallKitUI: \(didSuppressCallKitUI)")
        pendingEndStatus = status
        guard let uuid = currentSession?.callUUID else {
            print("☎️ [CallManager] endCurrentCall — no session UUID, finalizing directly")
            finalizeCall(status: status, emitStatus: true)
            return
        }
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        if didSuppressCallKitUI {
            // Foreground path: CallKit was already dismissed, finalize directly.
            print("☎️ [CallManager] endCurrentCall — foreground path, finalizing directly")
            finalizeCall(status: status, emitStatus: true)
        } else {
            print("☎️ [CallManager] endCurrentCall — background path, using CXEndCallAction")
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
        print("☎️ [CallManager] handleIncomingPush — raw payload: \(stringifyPushPayload(payload))")
        let incomingThreadId = threadId(from: payload)
        let incomingPayload = CallPayload(userInfo: payload)
        let parsedStatus = parsedStatusEvent(from: payload)

        print("☎️ [CallManager] handleIncomingPush — parsed threadId: \(incomingThreadId ?? "nil"), source: \(threadIdSource(from: payload)?.rawValue ?? "none"), parsedStatus: \(parsedStatus?.status.rawValue ?? "nil"), statusSource: \(parsedStatus?.source.rawValue ?? "none"), currentSession: \(currentSession?.payload.threadId ?? "none"), state: \(currentSession.map { String(describing: $0.state) } ?? "nil"), isForeground: \(host?.isAppInForeground ?? false), didSuppressCallKitUI: \(didSuppressCallKitUI)")

        if shouldSuppressDuplicatePush(threadId: incomingThreadId, status: parsedStatus?.status.rawValue ?? incomingStatus(from: payload, payload: incomingPayload)) {
            print("☎️ [CallManager] handleIncomingPush — duplicate suppression blocked handling")
            completion()
            return
        }

        if let directStatus = parsedStatus?.status {
            print("☎️ [CallManager] handleIncomingPush — treating payload as terminal status: \(directStatus.rawValue)")
            if incomingThreadId == currentSession?.payload.threadId {
                handleRemoteTermination(status: directStatus)
            }
            completion()
            return
        }

        if let session = currentSession, session.state != .idle {
            if let incomingPayload, incomingPayload.threadId == session.payload.threadId {
                print("☎️ [CallManager] handleIncomingPush — duplicate push for active thread, reporting transient")
                reportTransientIncomingCallIfNeeded(payload: incomingPayload, completion: completion)
                return
            }

            if let incomingThreadId, incomingThreadId != session.payload.threadId {
                print("☎️ [CallManager] handleIncomingPush — different thread while busy, emitting busy")
                emitBusyStatus(for: incomingThreadId, whileActiveThreadIdIs: session.payload.threadId, completion: {})
                reportTransientIncomingCallIfNeeded(payload: incomingPayload, endStatus: .busy, completion: completion)
            } else {
                print("☎️ [CallManager] handleIncomingPush — unknown thread while busy, marking failed")
                reportTransientIncomingCallIfNeeded(payload: incomingPayload, markFailed: true, completion: completion)
            }
            return
        }

        guard let payload = incomingPayload else {
            print("☎️ [CallManager] handleIncomingPush — invalid payload, marking failed")
            reportTransientIncomingCallIfNeeded(payload: nil, markFailed: true, completion: completion)
            return
        }

        let incomingPresentationMode: IncomingCallPresentationMode = shouldBypassCallKitForIncomingCall() ? .inApp : .callKit
        print("☎️ [CallManager] handleIncomingPush — treating payload as new incoming call, creating session presentationMode: \(incomingPresentationMode)")
        host?.prepareForIncomingCall()
        createIncomingSession(with: payload, presentationMode: incomingPresentationMode)
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

    private func createIncomingSession(with payload: CallPayload, presentationMode: IncomingCallPresentationMode) {
        pendingDismissWorkItem?.cancel()
        stopElapsedTimer()
        stopListeningForCallStatus()
        currentSession = CallSession(
            payload: payload,
            state: .ringing,
            incomingPresentationMode: presentationMode
        )
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

        if session.hasReportedIncomingCallToSystem || session.hasPresentedIncomingCallUI {
            print("☎️ [CallManager] reportIncomingCall — already handled for UUID: \(session.callUUID)")
            completion()
            return
        }

        if session.incomingPresentationMode == .inApp {
            print("☎️ [CallManager] reportIncomingCall — foreground path, bypassing CallKit for UUID: \(session.callUUID)")
            didSuppressCallKitUI = true
            startUnansweredTimer()
            transport?.emit(status: .visible, threadId: session.payload.threadId, completion: nil)
            presentIncomingCallIfNeeded()
            completion()
            return
        }

        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        let update = CXCallUpdate()
        update.localizedCallerName = session.payload.callerName
        update.hasVideo = false

        updateCurrentSession {
            $0.hasReportedIncomingCallToSystem = true
        }
        print("☎️ [CallManager] reportIncomingCall — reporting to CXProvider, UUID: \(session.callUUID)")
        provider.reportNewIncomingCall(with: session.callUUID, update: update) { [weak self] error in
            guard let self else {
                completion()
                return
            }
            DispatchQueue.main.async {
                if let error {
                    print("☎️ [CallManager] reportIncomingCall — CXProvider error: \(error.localizedDescription)")
                    self.updateCurrentSession {
                        $0.hasReportedIncomingCallToSystem = false
                    }
                } else {
                    self.startUnansweredTimer()
                    self.transport?.emit(status: .visible, threadId: session.payload.threadId, completion: nil)
                    print("☎️ [CallManager] reportIncomingCall — success, CallKit active")
                }
                completion()
            }
        }
        #else
        startUnansweredTimer()
        transport?.emit(status: .visible, threadId: session.payload.threadId, completion: nil)
        didSuppressCallKitUI = true
        presentIncomingCallIfNeeded()
        completion()
        #endif
    }

    private func reportTransientIncomingCallIfNeeded(
        payload: CallPayload?,
        endStatus: CallStatus? = nil,
        markFailed: Bool = false,
        completion: @escaping () -> Void
    ) {
        if shouldBypassCallKitForIncomingCall() {
            print("☎️ [CallManager] reportTransient — skipping CallKit transient while app is foregrounded")
            completion()
            return
        }

        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        let update = CXCallUpdate()
        update.localizedCallerName = payload?.callerName ?? configuration.appName
        update.hasVideo = false

        let callUUID = UUID()
        print("☎️ [CallManager] reportTransient — creating transient call UUID: \(callUUID), endStatus: \(endStatus?.rawValue ?? "nil"), markFailed: \(markFailed)")
        provider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else {
                    completion()
                    return
                }

                if markFailed {
                    print("☎️ [CallManager] reportTransient — ending transient as .failed")
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .failed)
                } else if let endStatus {
                    print("☎️ [CallManager] reportTransient — ending transient with status: \(endStatus.rawValue)")
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: self.callEndedReason(for: endStatus))
                } else {
                    // No explicit end status — this is a duplicate push for a
                    // call we are already handling. We MUST immediately end
                    // this transient call, otherwise CallKit will display a
                    // new full-screen incoming call overlay (especially on iPad).
                    print("☎️ [CallManager] reportTransient — duplicate push, ending transient as .answeredElsewhere")
                    self.provider.reportCall(with: callUUID, endedAt: Date(), reason: .answeredElsewhere)
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

    private func presentIncomingCallIfNeeded() {
        guard let session = currentSession else { return }
        guard !session.hasPresentedIncomingCallUI else {
            print("☎️ [CallManager] presentIncomingCallIfNeeded — already presented for UUID: \(session.callUUID)")
            return
        }
        guard isCallUIHostReady else {
            print("☎️ [CallManager] presentIncomingCallIfNeeded — deferring until host is ready")
            pendingCallUIPresentation = .incoming
            return
        }

        updateCurrentSession {
            $0.hasPresentedIncomingCallUI = true
        }
        guard let currentSession else { return }
        pendingCallUIPresentation = nil

        let model = incomingViewModel ?? IncomingCallViewModel()
        model.onAccept = { [weak self] in
            self?.stopRingtone()
            self?.answerCurrentCall()
        }
        model.onDecline = { [weak self] in
            self?.stopRingtone()
            self?.declineCurrentCall()
        }
        model.update(session: currentSession, configuration: configuration)
        incomingViewModel = model
        let controller = UIHostingController(rootView: IncomingCallView(model: model))
        controller.restorationIdentifier = "TevioIncomingCallController"
        controller.modalPresentationStyle = .fullScreen
        incomingCallController = controller
        host?.presentIncomingCall(controller)
        playRingtoneIfNeeded()
    }

    private func presentActiveCall(fromCallKit: Bool) {
        guard let session = currentSession else { return }
        guard isCallUIHostReady else {
            print("☎️ [CallManager] presentActiveCall — deferring until host is ready, fromCallKit: \(fromCallKit)")
            pendingCallUIPresentation = .active(fromCallKit: fromCallKit)
            return
        }

        pendingCallUIPresentation = nil
        if fromCallKit {
            print("☎️ [CallManager] presentActiveCall — resuming deferred active UI after host readiness")
        }
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
        controller.restorationIdentifier = "TevioActiveCallController"
        controller.modalPresentationStyle = .fullScreen
        activeCallController = controller

        if let incomingController = incomingCallController,
           let presenter = incomingController.presentingViewController {
            incomingController.dismiss(animated: false) { [weak self] in
                guard let self else { return }
                self.incomingCallController = nil
                presenter.present(controller, animated: true)
                self.fulfillPendingAnswerActionIfNeeded(reason: "active_ui_presented_after_incoming_dismiss")
            }
            return
        }

        host?.presentActiveCall(controller)
        fulfillPendingAnswerActionIfNeeded(reason: "active_ui_presented")
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
        withLifecycleBackgroundTask(named: "TevioCallKit.AnswerCall") {
            guard var session = currentSession else { return }
            cancelUnansweredTimer()
            pendingEndStatus = nil
            stopRingtone()
            pendingCallUIPresentation = nil
            cancelJoinChannelFallback()
            hasStartedJoiningCurrentCall = false
            host?.prepareForAnsweredCall()
            transport?.connectIfNeeded()
            audioEngine.configure(with: session.payload)
            session.state = .connecting
            currentSession = session
            shouldJoinOnAudioActivation = fromCallKit
            presentActiveCall(fromCallKit: fromCallKit)
            if fromCallKit {
                scheduleJoinChannelFallback()
            } else {
                beginJoiningCurrentCall(source: "foreground_answer")
            }
            updateActiveCallStatus(text: configuration.connectingText)
        }
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
        withLifecycleBackgroundTask(named: "TevioCallKit.FinalizeCall") {
            let callUUID = currentSession?.callUUID
            pendingDismissWorkItem?.cancel()
            cancelUnansweredTimer()
            stopElapsedTimer()
            cancelJoinChannelFallback()
            audioEngine.leaveChannel()

            if emitStatus, let threadId = currentSession?.payload.threadId {
                transport?.emit(status: status, threadId: threadId, completion: nil)
                if shouldClearRemoteStatus(after: status) {
                    transport?.emit(status: .none, threadId: threadId, completion: nil)
                }
            }

            fulfillPendingAnswerActionIfNeeded(reason: "call_finalizing")

            stopListeningForCallStatus()
            updateActiveCallStatus(text: message(for: status))
            stopRingtone()
            #if canImport(CallKit) && !targetEnvironment(macCatalyst)
            if let callUUID, !didSuppressCallKitUI {
                // Only report to CallKit if we haven't already suppressed it.
                // When didSuppressCallKitUI is true, the call was already reported
                // as .answeredElsewhere during the foreground suppression.
                print("☎️ [CallManager] finalizeCall — reporting call ended to CXProvider")
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
        pendingCallUIPresentation = nil
        shouldJoinOnAudioActivation = false
        hasStartedJoiningCurrentCall = false
        cancelJoinChannelFallback()
        #if canImport(CallKit) && !targetEnvironment(macCatalyst)
        pendingAnswerActionTimeoutWorkItem?.cancel()
        pendingAnswerActionTimeoutWorkItem = nil
        pendingAnswerAction = nil
        #endif
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

    private func shouldBypassCallKitForIncomingCall() -> Bool {
        host?.isAppInForeground == true
    }

    private var isCallUIHostReady: Bool {
        host?.isCallUIHostReady == true
    }

    private func updateCurrentSession(_ update: (inout CallSession) -> Void) {
        guard var session = currentSession else { return }
        update(&session)
        currentSession = session
    }

    private func processPendingCallUIPresentationIfPossible() {
        guard isCallUIHostReady, let pendingCallUIPresentation else { return }
        print("☎️ [CallManager] processPendingCallUIPresentationIfPossible — resuming pending UI: \(pendingCallUIPresentation)")

        switch pendingCallUIPresentation {
        case .incoming:
            presentIncomingCallIfNeeded()
        case .active(let fromCallKit):
            presentActiveCall(fromCallKit: fromCallKit)
        }
    }

    private func beginJoiningCurrentCall(source: String) {
        guard currentSession != nil else {
            print("☎️ [CallManager] beginJoiningCurrentCall — skipped source=\(source), no current session")
            return
        }
        guard !hasStartedJoiningCurrentCall else {
            print("☎️ [CallManager] beginJoiningCurrentCall — skipped duplicate join source=\(source)")
            return
        }

        print("☎️ [CallManager] beginJoiningCurrentCall — joining source=\(source)")
        hasStartedJoiningCurrentCall = true
        shouldJoinOnAudioActivation = false
        cancelJoinChannelFallback()
        audioEngine.joinChannel()
    }

    private func scheduleJoinChannelFallback() {
        cancelJoinChannelFallback()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            print("☎️ [CallManager] scheduleJoinChannelFallback — firing fallback join")
            self.beginJoiningCurrentCall(source: "fallback")
        }
        joinChannelFallbackWorkItem = workItem
        print("☎️ [CallManager] scheduleJoinChannelFallback — scheduled in \(joinChannelFallbackDelay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + joinChannelFallbackDelay, execute: workItem)
    }

    private func cancelJoinChannelFallback() {
        joinChannelFallbackWorkItem?.cancel()
        joinChannelFallbackWorkItem = nil
    }

    #if canImport(CallKit) && !targetEnvironment(macCatalyst)
    private func schedulePendingAnswerActionFulfillmentTimeout() {
        pendingAnswerActionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fulfillPendingAnswerActionIfNeeded(reason: "timeout")
        }
        pendingAnswerActionTimeoutWorkItem = workItem
        print("☎️ [CallManager] CXProvider.answerCall — scheduled deferred fulfill timeout in \(answerActionFulfillmentTimeout)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + answerActionFulfillmentTimeout, execute: workItem)
    }

    private func fulfillPendingAnswerActionIfNeeded(reason: String) {
        guard let pendingAnswerAction else { return }
        pendingAnswerActionTimeoutWorkItem?.cancel()
        pendingAnswerActionTimeoutWorkItem = nil
        print("☎️ [CallManager] CXProvider.answerCall — fulfilling deferred action reason=\(reason)")
        self.pendingAnswerAction = nil
        pendingAnswerAction.fulfill()
    }
    #endif

    private func withLifecycleBackgroundTask(named name: String, operation: () -> Void) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            if backgroundTaskIdentifier != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
                backgroundTaskIdentifier = .invalid
            }
        }
        operation()
        guard backgroundTaskIdentifier != .invalid else { return }
        let taskIdentifier = backgroundTaskIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + lifecycleBackgroundTaskDuration) {
            guard taskIdentifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(taskIdentifier)
        }
        #else
        operation()
        #endif
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
        let rawStatus = CallPushPayloadParser.stringValue(forKeys: ["status", "type"], in: payload)
        guard let rawStatus else { return nil }
        switch rawStatus.value {
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
        CallPushPayloadParser.stringValue(forKeys: ["thread_id", "threadId"], in: payload)?.value
    }

    private func threadIdSource(from payload: [AnyHashable: Any]) -> CallPushPayloadSource? {
        CallPushPayloadParser.stringValue(forKeys: ["thread_id", "threadId"], in: payload)?.source
    }

    private func parsedStatusEvent(from payload: [AnyHashable: Any]) -> (status: CallStatus, source: CallPushPayloadSource)? {
        guard
            let rawStatus = CallPushPayloadParser.stringValue(forKeys: ["status", "type"], in: payload),
            let status = directTerminationStatus(from: payload)
        else {
            return nil
        }
        return (status: status, source: rawStatus.source)
    }

    private func incomingStatus(from payload: [AnyHashable: Any], payload incomingPayload: CallPayload?) -> String? {
        if let rawStatus = CallPushPayloadParser.stringValue(forKeys: ["status", "type"], in: payload)?.value {
            return rawStatus
        }
        return incomingPayload?.type
    }

    private func shouldSuppressDuplicatePush(threadId: String?, status: String?) -> Bool {
        pruneExpiredPushEventTimestamps()
        guard
            let threadId,
            let status
        else {
            return false
        }

        let key = "\(threadId)|\(status)"
        let now = Date()
        if let recentDate = recentPushEventTimestamps[key], now.timeIntervalSince(recentDate) < duplicatePushSuppressionWindow {
            return true
        }

        recentPushEventTimestamps[key] = now
        return false
    }

    private func pruneExpiredPushEventTimestamps() {
        let now = Date()
        recentPushEventTimestamps = recentPushEventTimestamps.filter { _, timestamp in
            now.timeIntervalSince(timestamp) < duplicatePushSuppressionWindow
        }
    }

    private func stringifyPushPayload(_ payload: [AnyHashable: Any]) -> String {
        let normalizedPayload = CallPushPayloadParser.dictionary(for: .topLevel, in: payload) ?? [:]
        guard
            JSONSerialization.isValidJSONObject(normalizedPayload),
            let data = try? JSONSerialization.data(withJSONObject: normalizedPayload, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: payload)
        }
        return string
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
        print("☎️ [CallManager] CXProvider.answerCall — received state: \(currentSession.map { String(describing: $0.state) } ?? "nil"), didSuppressCallKitUI: \(didSuppressCallKitUI), hostReady: \(isCallUIHostReady)")
        // Only process if the call is still in ringing state.
        // If the call was already answered via the foreground path,
        // currentSession will be in .connecting or .active state.
        if currentSession?.state == .ringing, !didSuppressCallKitUI {
            pendingAnswerAction = action
            print("☎️ [CallManager] CXProvider.answerCall — deferring fulfill until answer transition is safe")
            schedulePendingAnswerActionFulfillmentTimeout()
            handleAnsweredCall(fromCallKit: true)
        } else {
            print("☎️ [CallManager] CXProvider.answerCall — skipped (already handled or suppressed)")
            action.fulfill()
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("☎️ [CallManager] CXProvider.endCall — session: \(currentSession != nil), didSuppressCallKitUI: \(didSuppressCallKitUI)")
        // Only process if there's still an active session that hasn't been finalized.
        if currentSession != nil, !didSuppressCallKitUI {
            let status = pendingEndStatus ?? ((currentSession?.state == .ringing) ? .declined : .ended)
            finalizeCall(status: status, emitStatus: pendingEndStatus != nil || status == .declined)
        } else {
            print("☎️ [CallManager] CXProvider.endCall — skipped (already handled or suppressed)")
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        audioEngine.didActivateAudioSession(audioSession)
        if shouldJoinOnAudioActivation {
            print("☎️ [CallManager] provider.didActivateAudioSession — joining from audio activation")
            beginJoiningCurrentCall(source: "audio_activation")
        } else {
            print("☎️ [CallManager] provider.didActivateAudioSession — no pending audio-activation join")
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
