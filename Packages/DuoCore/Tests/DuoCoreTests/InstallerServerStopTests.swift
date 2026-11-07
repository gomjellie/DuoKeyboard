import DuoCore
@testable import DuoKit
import Foundation
import Testing

/// Stopping the input method server waits (bounded) for it to exit (review safety-5). The waits run
/// against injected liveness checks, plus one short-lived child process that exits by itself; no
/// signal is ever sent to a real process here.
@Suite("Installer · server stop")
struct InstallerServerStopTests {
    /// Counts liveness polls; a pid is alive for its first `polls[pid]` checks.
    final class FakeProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [pid_t: Int]
        private(set) var signalled: [pid_t] = []

        init(_ polls: [pid_t: Int]) { remaining = polls }

        func send(_ pid: pid_t) -> Bool {
            lock.withLock { signalled.append(pid) }
            return remaining[pid] != nil
        }

        func isAlive(_ pid: pid_t) -> Bool {
            lock.withLock {
                guard let left = remaining[pid], left > 0 else { return false }
                remaining[pid] = left - 1
                return true
            }
        }
    }

    @Test func waitsUntilEveryProcessHasExited() {
        let fake = FakeProcesses([101: 3, 102: 6])
        let exited = InputMethodInstaller.terminate([101, 102], timeout: .seconds(4), pollInterval: .milliseconds(1),
                                                    send: fake.send, isAlive: fake.isAlive)
        #expect(exited)
        #expect(fake.signalled == [101, 102])
        #expect(!fake.isAlive(101) && !fake.isAlive(102))
    }

    @Test func givesUpAfterTheTimeout() {
        let clock = ContinuousClock()
        let start = clock.now
        let exited = InputMethodInstaller.waitForExit(of: [7], timeout: .milliseconds(200), pollInterval: .milliseconds(20),
                                                      isAlive: { _ in true })
        let elapsed = clock.now - start
        #expect(!exited)
        #expect(elapsed >= .milliseconds(200))
        #expect(elapsed < .seconds(2))
    }

    @Test func onlyWaitsForProcessesThatWereSignalled() {
        // 202 is not ours (the signal is refused): never wait on it.
        let fake = FakeProcesses([201: 1])
        let exited = InputMethodInstaller.terminate([201, 202], timeout: .milliseconds(500), pollInterval: .milliseconds(1),
                                                    send: fake.send, isAlive: { pid in pid == 202 || fake.isAlive(pid) })
        #expect(exited)
    }

    @Test func nothingToStopIsImmediate() {
        #expect(InputMethodInstaller.waitForExit(of: [], timeout: .zero, isAlive: { _ in true }))
    }

    /// A real child that exits on its own: found by name, and the wait sees it go.
    @Test func findsAndOutwaitsARealChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["0.3"]
        try child.run()
        let pid = child.processIdentifier

        #expect(InputMethodInstaller.processIDs(named: "sleep").contains(pid))
        #expect(InputMethodInstaller.processExists(pid))
        #expect(InputMethodInstaller.waitForExit(of: [pid], timeout: .seconds(5), pollInterval: .milliseconds(20)))
        #expect(!InputMethodInstaller.processExists(pid))
    }

    @Test func neverListsThisProcess() {
        let me = ProcessInfo.processInfo.processName
        #expect(!InputMethodInstaller.processIDs(named: me).contains(getpid()))
    }
}
