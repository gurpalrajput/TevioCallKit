import Foundation
import Testing
import UIKit
@testable import TevioCallModule

@MainActor
struct TevioCallCoordinatorTests {
    @Test func outgoingInitializationFailureDoesNotLeaveSessionActive() async {
        let transport = MockTransport()
        let backend = MockBackend(mode: .failure)
        let host = MockHost()
        let audioEngine = NoopCallAudioEngine()
        let store = InMemorySessionStore()
        let logger = DefaultCallLogger()
        let coordinator = TevioCallCoordinator(
            transport: transport,
            backend: backend,
            host: host,
            audioEngine: audioEngine,
            configuration: CallUIConfiguration(appName: "Tevio"),
            sessionStore: store,
            logger: logger
        )

        coordinator.startOutgoingCall(request: OutgoingCallRequest(threadId: "thread-1"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(coordinator.currentSession == nil)
    }
}

private final class MockTransport: CallTransporting {
    func connectIfNeeded() {}
    func ensureConnected(timeout: TimeInterval, completion: @escaping (Bool) -> Void) { completion(true) }
    func emit(status: CallStatus, threadId: String, completion: (() -> Void)?) { completion?() }
    func startListening(threadId: String, handler: @escaping (RemoteCallStatusEvent) -> Void) {}
    func stopListening(threadId: String?) {}
}

private final class MockBackend: CallBackendProviding {
    enum Mode {
        case success
        case failure
    }

    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func initiateOutgoingCall(threadId: String, completion: @escaping (Result<CallPayload, Error>) -> Void) {
        switch mode {
        case .success:
            completion(.success(CallPayload(type: "AUDIO_CALL", threadId: threadId, uid: "1", agoraToken: "token", appId: "app", callerName: "Caller", role: .caller)))
        case .failure:
            completion(.failure(NSError(domain: "Test", code: 1)))
        }
    }

    func fetchThreadDetails(threadId: String, completion: @escaping (Result<CallThreadDetails, Error>) -> Void) {
        completion(.success(CallThreadDetails(name: "Caller", roleDescription: "Role")))
    }
}

private final class MockHost: CallHostCoordinating {
    var isAppInForeground: Bool = true
    func prepareForIncomingCall() {}
    func prepareForAnsweredCall() {}
    func presentIncomingCall(_ viewController: UIViewController) {}
    func presentActiveCall(_ viewController: UIViewController) {}
    func dismissCallUI(animated: Bool) {}
    func didUpdateVoIPToken(_ token: String) {}
}

private final class InMemorySessionStore: CallSessionStoring {
    var session: CallSession?
    var events: [PendingCallEvent] = []

    func saveCurrentSession(_ session: CallSession) { self.session = session }
    func loadCurrentSession() -> CallSession? { session }
    func clearCurrentSession() { session = nil }
    func enqueuePendingEvent(_ event: PendingCallEvent) { events.append(event) }
    func loadPendingEvents() -> [PendingCallEvent] { events }
    func removePendingEvent(id: UUID) { events.removeAll { $0.id == id } }
}
