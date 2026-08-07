import Testing
@testable import TevioCallModule

struct TevioCallStateMachineTests {
    @Test func validStateTransitionsRemainAllowed() {
        #expect(TevioCallStateMachine.canTransition(from: .idle, to: .incomingReceived))
        #expect(TevioCallStateMachine.canTransition(from: .incomingReceived, to: .ringing))
        #expect(TevioCallStateMachine.canTransition(from: .ringing, to: .answering))
        #expect(TevioCallStateMachine.canTransition(from: .answering, to: .connecting))
        #expect(TevioCallStateMachine.canTransition(from: .connecting, to: .active))
        #expect(TevioCallStateMachine.canTransition(from: .active, to: .ending))
        #expect(TevioCallStateMachine.canTransition(from: .ending, to: .ended))
    }

    @Test func invalidTransitionsStayBlocked() {
        #expect(!TevioCallStateMachine.canTransition(from: .idle, to: .active))
        #expect(!TevioCallStateMachine.canTransition(from: .ended, to: .active))
        #expect(!TevioCallStateMachine.canTransition(from: .ringing, to: .active))
    }
}
