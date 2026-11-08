@testable import DuoKit
import Testing

/// `ping` → `pong`: a waiter takes only the answer to its own ping, so Settings' polling cannot
/// stand in for a learning command's barrier.
@Suite("Host · input method ping")
struct HostPingTests {
    @Test func aPongAnswersThePingWhoseTokenItCarries() {
        #expect(InputMethodPing.answers([DuoIDs.pingTokenKey: "A", "version": "1"], token: "A"))
    }

    @Test func aPongForAnotherPingIsNotTheAnswer() {
        #expect(!InputMethodPing.answers([DuoIDs.pingTokenKey: "B"], token: "A"))
    }

    @Test func aPongWithoutATokenStillAnswers() {
        // An input method from before the token: barriers must not all time out.
        #expect(InputMethodPing.answers(["version": "1", "modelLoaded": "true"], token: "A"))
    }
}
