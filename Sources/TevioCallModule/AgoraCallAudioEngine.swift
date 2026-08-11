import AVFoundation
#if canImport(AgoraRtcKit) && !targetEnvironment(macCatalyst)
import AgoraRtcKit
#endif

#if canImport(AgoraRtcKit) && !targetEnvironment(macCatalyst)
public final class AgoraCallAudioEngine: NSObject, CallAudioEngining, CallAudioErrorReporting {
    public var onRemoteUserJoined: (() -> Void)?
    public var onRemoteUserLeft: (() -> Void)?
    public var onRemoteMuteChanged: ((Bool) -> Void)?
    public var onError: ((String) -> Void)?

    private var agoraEngine: AgoraRtcEngineKit?
    private var payload: CallPayload?

    public override init() {
        super.init()
    }

    public func configure(with payload: CallPayload) {
        self.payload = payload
        agoraEngine = AgoraRtcEngineKit.sharedEngine(withAppId: payload.appId, delegate: self)
        agoraEngine?.disableVideo()
        agoraEngine?.setChannelProfile(.communication)
        let speakerResult = agoraEngine?.setEnableSpeakerphone(false) ?? -1
        if speakerResult != 0 {
            onError?("Unable to configure call audio.")
        }
    }

    public func joinChannel() {
        guard let payload else { return }
        let result = agoraEngine?.joinChannel(
            byToken: payload.agoraToken,
            channelId: payload.threadId,
            info: nil,
            uid: UInt(payload.uid) ?? 0
        ) ?? -1

        if result != 0 {
            onError?("Unable to join the call channel.")
        }
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
        agoraEngine?.setEnableSpeakerphone(isEnabled)
    }

    public func didActivateAudioSession(_ audioSession: AVAudioSession) {}
}

extension AgoraCallAudioEngine: AgoraRtcEngineDelegate {
    public func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        onError?("Call audio error: \(errorCode.rawValue)")
    }

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
#else
public final class AgoraCallAudioEngine: NSObject, CallAudioEngining, CallAudioErrorReporting {
    public var onRemoteUserJoined: (() -> Void)?
    public var onRemoteUserLeft: (() -> Void)?
    public var onRemoteMuteChanged: ((Bool) -> Void)?
    public var onError: ((String) -> Void)?

    public override init() {
        super.init()
    }

    public func configure(with payload: CallPayload) {}

    public func joinChannel() {}

    public func leaveChannel() {}

    public func setMuted(_ isMuted: Bool) {}

    public func setSpeakerEnabled(_ isEnabled: Bool) {}

    public func didActivateAudioSession(_ audioSession: AVAudioSession) {}
}
#endif
