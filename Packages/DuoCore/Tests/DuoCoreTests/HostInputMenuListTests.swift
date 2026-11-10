@testable import DuoKit
import Foundation
import Testing

/// The menu bar's input menu reads a session-wide list of sources. After the user allows Duo the
/// list can lack Duo: Duo's entry is added once, and only while Duo is on.
@Suite("Host · input menu list")
struct HostInputMenuListTests {
    static var abc: [String: Any] {
        ["InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": 252, "KeyboardLayout Name": "ABC"]
    }
    static var duo: [String: Any] {
        ["Bundle ID": DuoIDs.inputMethodBundleID, "InputSourceKind": "Keyboard Input Method"]
    }

    static func same(_ lhs: [[String: Any]]?, _ rhs: [[String: Any]]) -> Bool {
        lhs.map { ($0 as NSArray).isEqual(rhs) } ?? false
    }

    @Test("a list without Duo gets Duo's entry at the end")
    func addsMissingEntry() {
        let korean: [String: Any] = [
            "Bundle ID": "com.apple.inputmethod.Korean", "Input Mode": "com.apple.inputmethod.Korean.2SetKorean",
            "InputSourceKind": "Input Mode",
        ]
        #expect(Self.same(InputMenuList.adding(Self.duo, to: [Self.abc]), [Self.abc, Self.duo]))
        #expect(Self.same(InputMenuList.adding(Self.duo, to: [Self.abc, korean]), [Self.abc, korean, Self.duo]))
    }

    @Test("a list that has Duo stays; an empty list is left for the next reader to build")
    func leavesCurrentAndEmptyLists() {
        #expect(InputMenuList.adding(Self.duo, to: [Self.abc, Self.duo]) == nil)
        #expect(InputMenuList.adding(Self.duo, to: []) == nil)
        #expect(InputMenuList.adding(["InputSourceKind": "Keyboard Input Method"], to: [Self.abc]) == nil)
    }

    @Test("the entry is the one macOS wrote to its allow list, else the two keys of an input method")
    func entryComesFromAllowList() {
        let written: [String: Any] = [
            "Bundle ID": DuoIDs.inputMethodBundleID, "InputSourceKind": "Keyboard Input Method", "Extra": 1,
        ]
        let other: [String: Any] = ["Bundle ID": "com.example.other", "InputSourceKind": "Non Keyboard Input Method"]
        let fromList = InputMenuList.entry(for: DuoIDs.inputMethodBundleID, allowList: [other, written])
        #expect((fromList as NSDictionary).isEqual(to: written))
        let built = InputMenuList.entry(for: DuoIDs.inputMethodBundleID, allowList: [other])
        #expect((built as NSDictionary).isEqual(to: Self.duo))
    }

    @Test("the list survives the XML property list HIToolbox reads")
    func encodesAsXMLPropertyList() throws {
        let data = try #require(InputMenuList.encode([Self.abc, Self.duo]))
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "<?xml")
        #expect(Self.same(InputMenuList.decode(data), [Self.abc, Self.duo]))
    }

    @Test("data that is not a list of dictionaries is not a list")
    func rejectsOtherData() throws {
        #expect(InputMenuList.decode(Data("not a property list".utf8)) == nil)
        let strings = try PropertyListSerialization.data(fromPropertyList: ["ABC"], format: .xml, options: 0)
        #expect(InputMenuList.decode(strings) == nil)
        let dictionary = try PropertyListSerialization.data(fromPropertyList: Self.abc, format: .xml, options: 0)
        #expect(InputMenuList.decode(dictionary) == nil)
    }

    @Test("while Duo is off the list is not touched")
    func doesNothingWhileDuoIsOff() {
        #expect(!InputMenuList.addDuoIfMissing(isEnabled: false))
    }
}
