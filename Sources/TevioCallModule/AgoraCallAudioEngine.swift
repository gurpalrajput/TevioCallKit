import AVFoundation
#if canImport(AgoraRtcKit) && !targetEnvironment(macCatalyst)
import AgoraRtcKit
#endif

#if canImport(AgoraRtcKit) && !targetEnvironment(macCatalyst)
public final class AgoraCallAudioEngine: NSObject, CallAudioEngining {
    public var onRemoteUserJoined: (() -> Void)?
    public var onRemoteUserLeft: (() -> Void)?
    public var onRemoteMuteChanged: ((Bool) -> Void)?

    private var agoraEngine: AgoraRtcEngineKit?
    private var payload: CallPayload?
    private var joinedChannelID: String?

    public override init() {
        super.init()
    }

    public func configure(with payload: CallPayload) {
        if self.payload?.threadId == payload.threadId, agoraEngine != nil {
            return
        }
        self.payload = payload
        agoraEngine = AgoraRtcEngineKit.sharedEngine(withAppId: payload.appId, delegate: self)
        agoraEngine?.disableVideo()
        agoraEngine?.setChannelProfile(.communication)
        agoraEngine?.setEnableSpeakerphone(false)
    }

    public func joinChannel() {
        guard let payload else { return }
        guard joinedChannelID != payload.threadId else { return }
        agoraEngine?.joinChannel(
            byToken: payload.agoraToken,
            channelId: payload.threadId,
            info: nil,
            uid: UInt(payload.uid) ?? 0
        )
        joinedChannelID = payload.threadId
    }

    public func leaveChannel() {
        guard agoraEngine != nil else { return }
        agoraEngine?.leaveChannel(nil)
        AgoraRtcEngineKit.destroy()
        agoraEngine = nil
        joinedChannelID = nil
    }

    public func setMuted(_ isMuted: Bool) {
        agoraEngine?.muteLocalAudioStream(isMuted)
    }

    public func setSpeakerEnabled(_ isEnabled: Bool) {
        agoraEngine?.setEnableSpeakerphone(isEnabled)
    }

    public func didActivateAudioSession(_ audioSession: AVAudioSession) {}

    public func didDeactivateAudioSession(_ audioSession: AVAudioSession) {}
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
#else
public final class AgoraCallAudioEngine: NSObject, CallAudioEngining {
    public var onRemoteUserJoined: (() -> Void)?
    public var onRemoteUserLeft: (() -> Void)?
    public var onRemoteMuteChanged: ((Bool) -> Void)?

    public override init() {
        super.init()
    }

    public func configure(with payload: CallPayload) {}

    public func joinChannel() {}

    public func leaveChannel() {}

    public func setMuted(_ isMuted: Bool) {}

    public func setSpeakerEnabled(_ isEnabled: Bool) {}

    public func didActivateAudioSession(_ audioSession: AVAudioSession) {}

    public func didDeactivateAudioSession(_ audioSession: AVAudioSession) {}
}
#endif
