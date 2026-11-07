import DuoCore
import DuoKit
import Foundation
import Testing

@Suite("Selection conversion feedback")
struct HUDSelectionConversionTests {
    @Test("a usable selection in a client that can replace text is converted",
          arguments: [ReplacementSupport.full, .beforeCaretOnly])
    func converts(replacement: ReplacementSupport) {
        let range = NSRange(location: 4, length: 6)
        #expect(SelectionConversionCheck.check(replacement: replacement, selection: range) == .convert(range))
        let longest = NSRange(location: 0, length: SelectionConverter.maxLength)
        #expect(SelectionConversionCheck.check(replacement: replacement, selection: longest) == .convert(longest))
    }

    @Test("nothing to convert beeps instead of claiming the app cannot change text", arguments: [
        nil,
        NSRange(location: 12, length: 0),                                   // a caret, or a composition
        NSRange(location: NSNotFound, length: 0),
        NSRange(location: 0, length: SelectionConverter.maxLength + 1),     // over the cap
    ] as [NSRange?])
    func nothingToConvert(selection: NSRange?) {
        #expect(SelectionConversionCheck.check(replacement: .full, selection: selection) == .nothingToConvert)
    }

    @Test("a client that cannot replace text says so, whatever is selected", arguments: [
        nil, NSRange(location: 0, length: 0), NSRange(location: 0, length: 5),
    ] as [NSRange?])
    func cannotChange(selection: NSRange?) {
        #expect(SelectionConversionCheck.check(replacement: .none, selection: selection) == .cannotChange)
    }
}
