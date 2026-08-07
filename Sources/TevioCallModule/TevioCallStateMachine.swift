import Foundation

enum TevioCallStateMachine {
    static func canTransition(from: CallSessionState, to: CallSessionState) -> Bool {
        if from == to {
            return true
        }

        switch (from, to) {
        case (.idle, .initializingOutgoing),
             (.idle, .incomingReceived),
             (.initializingOutgoing, .outgoingInitialized),
             (.initializingOutgoing, .failed),
             (.outgoingInitialized, .connecting),
             (.outgoingInitialized, .ending),
             (.incomingReceived, .ringing),
             (.incomingReceived, .answering),
             (.incomingReceived, .declining),
             (.ringing, .answering),
             (.ringing, .declining),
             (.ringing, .ending),
             (.answering, .connecting),
             (.answering, .ending),
             (.connecting, .active),
             (.connecting, .ending),
             (.active, .ending),
             (.declining, .ending),
             (.ending, .ended),
             (.failed, .idle),
             (.ended, .idle):
            return true
        default:
            return false
        }
    }
}
