@testable import DuoKit
import Foundation
import Testing

/// The holder of Secure Keyboard Entry comes from the login session of the current user only.
@Suite("Host · secure input owner")
struct HostSecureInputTests {
    private func session(uid: Int, pid: Int?) -> [String: Any] {
        var session: [String: Any] = ["kCGSSessionUserIDKey": NSNumber(value: uid), "kCGSSessionOnConsoleKey": true]
        if let pid { session["kCGSSessionSecureInputPID"] = NSNumber(value: pid) }
        return session
    }

    @Test func theHolderOfTheUsersSessionIsFound() {
        #expect(SecureInputOwner.pid(inConsoleUsers: [session(uid: 501, pid: 46626)], uid: 501) == 46626)
    }

    @Test func anotherUsersHolderIsIgnored() {
        let sessions = [session(uid: 502, pid: 900), session(uid: 501, pid: 46626)]
        #expect(SecureInputOwner.pid(inConsoleUsers: sessions, uid: 501) == 46626)
        #expect(SecureInputOwner.pid(inConsoleUsers: [session(uid: 502, pid: 900)], uid: 501) == nil)
    }

    @Test func aSessionWithoutTheKeyHasNoHolder() {
        #expect(SecureInputOwner.pid(inConsoleUsers: [session(uid: 501, pid: nil)], uid: 501) == nil)
        #expect(SecureInputOwner.pid(inConsoleUsers: [], uid: 501) == nil)
    }

    @Test func aZeroOrWrongTypedPidIsUnknown() {
        #expect(SecureInputOwner.pid(inConsoleUsers: [session(uid: 501, pid: 0)], uid: 501) == nil)
        let odd: [String: Any] = ["kCGSSessionUserIDKey": NSNumber(value: 501), "kCGSSessionSecureInputPID": "46626"]
        #expect(SecureInputOwner.pid(inConsoleUsers: [odd], uid: 501) == nil)
    }

    @Test(arguments: [
        (true, true, true, true),
        (true, true, false, false),
        (false, true, true, false),
        (true, false, true, false),
    ])
    func onlyAReadyDuoIsBlocked(installed: Bool, enabled: Bool, secure: Bool, blocked: Bool) {
        let state = InputMethodState(isInstalled: installed, isEnabled: enabled, isSecureInputActive: secure)
        #expect(state.isBlockedBySecureInput == blocked)
    }
}
