import AVFoundation
import AgoraRtcKit

public final class AgoraCallAudioEngine: NSObject, CallAudioEngining {
    public var onRemoteUserJoined: (() -> Void)?
    public var onRemoteUserLeft: (() -> Void)?
    public var onRemoteMuteChanged: ((Bool) -> Void)?
    public var onAudioRouteChanged: ((CallAudioRouteState) -> Void)?

    private var agoraEngine: AgoraRtcEngineKit?
    private var payload: CallPayload?
    private let audioSession = AVAudioSession.sharedInstance()
    private var routeChangeObserver: NSObjectProtocol?
    private var requestedRoute: CallAudioRouteState.Route = .receiver
    private var isApplyingRequestedRoute = false

    public override init() {
        super.init()
        startObservingAudioRouteChanges()
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    public func configure(with payload: CallPayload) {
        self.payload = payload
        agoraEngine = AgoraRtcEngineKit.sharedEngine(withAppId: payload.appId, delegate: self)
        agoraEngine?.disableVideo()
        agoraEngine?.setChannelProfile(.communication)
        requestedRoute = .receiver
        selectAudioRoute(.receiver)
    }

    public func joinChannel() {
        guard let payload else { return }
        agoraEngine?.joinChannel(
            byToken: payload.agoraToken,
            channelId: payload.threadId,
            info: nil,
            uid: UInt(payload.uid) ?? 0
        )
    }

    public func leaveChannel() {
        agoraEngine?.leaveChannel(nil)
        AgoraRtcEngineKit.destroy()
        agoraEngine = nil
    }

    public func setMuted(_ isMuted: Bool) {
        agoraEngine?.muteLocalAudioStream(isMuted)
    }

    public func setSpeakerEnabled(_ isEnabled: Bool) {
        selectAudioRoute(isEnabled ? .speaker : .receiver)
    }

    public func currentAudioRouteState() -> CallAudioRouteState {
        buildAudioRouteState()
    }

    public func selectAudioRoute(_ route: CallAudioRouteState.Route) {
        requestedRoute = route
        applyRequestedRoute()
    }

    public func didActivateAudioSession(_ audioSession: AVAudioSession) {
        applyRequestedRoute(notifyAfterApplying: false)
        notifyAudioRouteChanged()
    }
}

extension AgoraCallAudioEngine: AgoraRtcEngineDelegate {
    public func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinedOfUid uid: UInt, elapsed: Int) {
        onRemoteUserJoined?()
    }

    public func rtcEngine(_ engine: AgoraRtcEngineKit, didOfflineOfUid uid: UInt, reason: AgoraUserOfflineReason) {
        onRemoteUserLeft?()
    }

    public func rtcEngine(_ engine: AgoraRtcEngineKit, remoteAudioStateChangedOfUid uid: UInt, state: AgoraAudioRemoteState, reason: AgoraAudioRemoteReason, elapsed: Int) {
        onRemoteMuteChanged?(state == .stopped)
    }
}

private extension AgoraCallAudioEngine {
    func applyRequestedRoute(notifyAfterApplying: Bool = true) {
        guard !isApplyingRequestedRoute else { return }
        isApplyingRequestedRoute = true
        defer { isApplyingRequestedRoute = false }

        let route = resolvedRequestedRoute()
        do {
            switch route {
            case .receiver:
                try audioSession.overrideOutputAudioPort(.none)
                try audioSession.setPreferredInput(nil)
                if let builtInMicInput = builtInMicInput() {
                    try audioSession.setPreferredInput(builtInMicInput)
                }
                agoraEngine?.setEnableSpeakerphone(false)
            case .speaker:
                try audioSession.overrideOutputAudioPort(.speaker)
                try audioSession.setPreferredInput(nil)
                if let builtInMicInput = builtInMicInput() {
                    try audioSession.setPreferredInput(builtInMicInput)
                }
                agoraEngine?.setEnableSpeakerphone(true)
            case .bluetooth(let name):
                try audioSession.overrideOutputAudioPort(.none)
                try audioSession.setPreferredInput(nil)
                if let bluetoothInput = bluetoothInputs().first(where: { normalizedPortName($0.portName) == normalizedPortName(name) }) ?? bluetoothInputs().first {
                    try audioSession.setPreferredInput(bluetoothInput)
                }
                agoraEngine?.setEnableSpeakerphone(false)
            }
        } catch {
            agoraEngine?.setEnableSpeakerphone(route == .speaker)
        }

        if notifyAfterApplying {
            notifyAudioRouteChanged()
        }
    }
    func startObservingAudioRouteChanges() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            self?.handleAudioRouteChange()
        }
    }

    func handleAudioRouteChange() {
        guard !isApplyingRequestedRoute else { return }

        let routeState = buildAudioRouteState()
        guard shouldReapplyRequestedRoute(for: routeState) else {
            onAudioRouteChanged?(routeState)
            return
        }

        applyRequestedRoute()
    }

    func notifyAudioRouteChanged() {
        onAudioRouteChanged?(buildAudioRouteState())
    }

    func shouldReapplyRequestedRoute(for routeState: CallAudioRouteState) -> Bool {
        let requestedRoute = resolvedRequestedRoute()
        if routeState.currentRoute == requestedRoute {
            return false
        }

        switch requestedRoute {
        case .receiver, .speaker:
            return true
        case .bluetooth:
            return routeState.availableRoutes.contains(requestedRoute)
        }
    }

    func buildAudioRouteState() -> CallAudioRouteState {
        let bluetoothRoutes = bluetoothInputs().map { CallAudioRouteState.Route.bluetooth(name: $0.portName) }
        var availableRoutes: [CallAudioRouteState.Route] = [.receiver, .speaker]
        for route in bluetoothRoutes where !availableRoutes.contains(route) {
            availableRoutes.append(route)
        }

        let currentRoute = resolvedCurrentRoute(bluetoothRoutes: bluetoothRoutes)
        if !availableRoutes.contains(currentRoute) {
            availableRoutes.append(currentRoute)
        }

        return CallAudioRouteState(currentRoute: currentRoute, availableRoutes: availableRoutes)
    }

    func resolvedRequestedRoute() -> CallAudioRouteState.Route {
        switch requestedRoute {
        case .bluetooth(let name):
            return bluetoothInputs().map { CallAudioRouteState.Route.bluetooth(name: $0.portName) }.first(where: {
                if case .bluetooth(let candidateName) = $0 {
                    return normalizedPortName(candidateName) == normalizedPortName(name)
                }
                return false
            }) ?? requestedRoute
        case .receiver, .speaker:
            return requestedRoute
        }
    }

    func resolvedCurrentRoute(bluetoothRoutes: [CallAudioRouteState.Route]) -> CallAudioRouteState.Route {
        let outputs = audioSession.currentRoute.outputs
        if let bluetoothOutput = outputs.first(where: isBluetoothPort) {
            let name = bluetoothOutput.portName
            return bluetoothRoutes.first(where: {
                if case .bluetooth(let bluetoothName) = $0 {
                    return normalizedPortName(bluetoothName) == normalizedPortName(name)
                }
                return false
            }) ?? .bluetooth(name: name)
        }

        if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            return .speaker
        }

        return .receiver
    }

    func bluetoothInputs() -> [AVAudioSessionPortDescription] {
        (audioSession.availableInputs ?? []).filter { input in
            isBluetoothPort(input)
        }
    }

    func builtInMicInput() -> AVAudioSessionPortDescription? {
        (audioSession.availableInputs ?? []).first { $0.portType == .builtInMic }
    }

    func normalizedPortName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isBluetoothPort(_ port: AVAudioSessionPortDescription) -> Bool {
        switch port.portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return true
        default:
            return false
        }
    }
}
