import Testing
@testable import DuoCore

@Test func versionIsSet() {
    #expect(!DuoCore.version.isEmpty)
}
