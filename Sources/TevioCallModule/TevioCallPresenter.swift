import AVFoundation
import Foundation
import UIKit

@MainActor
final class TevioCallPresenter {
    private weak var host: CallHostCoordinating?
    private let logger: CallLogging
    private weak var incomingCallController: UIViewController?
    private weak var activeCallController: UIViewController?
    private var audioPlayer: AVAudioPlayer?
    private var pendingPresentation: (kind: PendingCallPresentation, sessionID: UUID)?

    init(host: CallHostCoordinating?, logger: CallLogging) {
        self.host = host
        self.logger = logger
    }

    var isAppInForeground: Bool {
        host?.isAppInForeground ?? hasForegroundScene
    }

    func prepareForIncomingCall() {
        host?.prepareForIncomingCall()
    }

    func prepareForAnsweredCall() {
        host?.prepareForAnsweredCall()
    }

    func presentIncomingCall(_ controller: UIViewController, for session: CallSession) {
        guard isAppInForeground else {
            setPendingPresentation(.incoming, sessionID: session.callUUID)
            return
        }
        guard shouldPresent(controllerKind: .incoming, sessionID: session.callUUID) else { return }
        incomingCallController = controller
        if let host {
            host.presentIncomingCall(controller)
        } else {
            presentUsingDefaultHost(controller)
        }
        clearPendingPresentation()
    }

    func presentActiveCall(_ controller: UIViewController, for session: CallSession, replacingIncoming: Bool) {
        guard isAppInForeground else {
            setPendingPresentation(.active, sessionID: session.callUUID)
            return
        }
        guard shouldPresent(controllerKind: .active, sessionID: session.callUUID) else { return }

        if replacingIncoming,
           let incomingController = incomingCallController,
           let presenter = incomingController.presentingViewController {
            incomingController.dismiss(animated: false) { [weak self] in
                presenter.present(controller, animated: true)
                self?.activeCallController = controller
                self?.incomingCallController = nil
            }
            clearPendingPresentation()
            return
        }

        activeCallController = controller
        if let host {
            host.presentActiveCall(controller)
        } else {
            presentUsingDefaultHost(controller)
        }
        clearPendingPresentation()
    }

    func dismissCallUI(animated: Bool) {
        if let incomingCallController, incomingCallController.presentingViewController != nil {
            incomingCallController.dismiss(animated: animated)
            self.incomingCallController = nil
            return
        }
        if let activeCallController, activeCallController.presentingViewController != nil {
            activeCallController.dismiss(animated: animated)
            self.activeCallController = nil
            return
        }
        host?.dismissCallUI(animated: animated)
    }

    func showError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        if let controller = topMostController() {
            if controller.presentedViewController is UIAlertController {
                return
            }
            controller.present(alert, animated: true)
            return
        }

        logger.log("UI", message: "\(title): \(message)", context: [:])
    }

    func setPendingPresentation(_ kind: PendingCallPresentation, sessionID: UUID) {
        pendingPresentation = (kind, sessionID)
    }

    func clearPendingPresentation() {
        pendingPresentation = nil
    }

    func handleDidEnterBackground() {
        logger.log("UI", message: "application entered background", context: [:])
    }

    func playRingtoneIfNeeded(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            audioPlayer?.play()
        } catch {
            audioPlayer = nil
        }
    }

    func stopRingtone() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private func shouldPresent(controllerKind: PendingCallPresentation, sessionID: UUID) -> Bool {
        if let pendingPresentation,
           pendingPresentation.kind == controllerKind,
           pendingPresentation.sessionID != sessionID {
            return false
        }
        if controllerKind == .incoming, incomingCallController != nil {
            return false
        }
        if controllerKind == .active, activeCallController != nil {
            return false
        }
        return true
    }

    private func presentUsingDefaultHost(_ controller: UIViewController) {
        guard let topController = topMostController() else { return }
        topController.present(controller, animated: true)
    }

    private var hasForegroundScene: Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            scene.activationState == .foregroundActive
        }
    }

    private func topMostController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        return topController(from: window?.rootViewController)
    }

    private func topController(from root: UIViewController?) -> UIViewController? {
        guard let root else { return nil }
        if let navigationController = root as? UINavigationController {
            return topController(from: navigationController.visibleViewController)
        }
        if let tabBarController = root as? UITabBarController {
            return topController(from: tabBarController.selectedViewController)
        }
        if let presentedViewController = root.presentedViewController {
            return topController(from: presentedViewController)
        }
        return root
    }
}
