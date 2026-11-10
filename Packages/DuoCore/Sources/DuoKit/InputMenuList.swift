import Carbon
import Foundation

/// The input menu in the menu bar does not ask TIS which sources are on. It reads a list that
/// HIToolbox keeps for the whole login session: the pasteboard
/// `AppleInputSourcesInUIOrderPasteboard`, an XML property list of flattened input sources in menu
/// order. A process writes the list when its own `TISEnableInputSource` or `TISDisableInputSource`
/// succeeds, and every reader trusts what is there.
///
/// When the user allows Duo in macOS's prompt, System Settings turns Duo on and nothing writes the
/// list again (seen on macOS 26.6.2). Duo is then on and selected, but the list has no Duo: the
/// input menu shows a generic keyboard icon, or 한A until it is opened and then no icon, and it
/// lists no input sources.
///
/// ``addDuoIfMissing(isEnabled:)`` adds Duo's entry and asks the input menu to read the list again.
public enum InputMenuList {
    static let pasteboardName = "AppleInputSourcesInUIOrderPasteboard"
    static let flavor = "AppleInputSourcesInUIOrderFlavor"
    static let bundleIDKey = "Bundle ID"
    static let kindKey = "InputSourceKind"
    static let inputMethodKind = "Keyboard Input Method"

    /// Posted by TIS after the enabled keyboard sources changed; the input menu builds its list again.
    static let enabledKeyboardSourcesChanged =
        Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)

    /// Duo's flattened input source: the entry macOS wrote to its list of allowed sources, else the
    /// two keys HIToolbox writes for an input method without modes.
    static func entry(for bundleID: String, allowList: [[String: Any]]) -> [String: Any] {
        allowList.first { $0[bundleIDKey] as? String == bundleID }
            ?? [bundleIDKey: bundleID, kindKey: inputMethodKind]
    }

    /// `list` with `entry` at the end. `nil` when there is nothing to do: the list already has the
    /// entry's bundle, or it is empty (the next reader then builds it from the sources that are on).
    static func adding(_ entry: [String: Any], to list: [[String: Any]]) -> [[String: Any]]? {
        guard !list.isEmpty, let bundleID = entry[bundleIDKey] as? String,
              !list.contains(where: { $0[bundleIDKey] as? String == bundleID }) else { return nil }
        return list + [entry]
    }

    static func decode(_ data: Data) -> [[String: Any]]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[String: Any]]
    }

    static func encode(_ list: [[String: Any]]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
    }

    /// Adds Duo to the list when Duo is on and the list lacks it, then asks every process to read
    /// the enabled sources again. Returns whether it changed the list.
    ///
    /// - Parameter isEnabled: TIS has Duo on. The list must not name a source that is off.
    @discardableResult
    public static func addDuoIfMissing(isEnabled: Bool = InputSourceManager.isEnabled) -> Bool {
        guard isEnabled else { return false }
        var reference: Pasteboard?
        guard PasteboardCreate(pasteboardName as CFString, &reference) == noErr, let pasteboard = reference else {
            return false
        }
        PasteboardSynchronize(pasteboard)
        let entry = entry(for: DuoIDs.inputMethodBundleID, allowList: InputMethodInstaller.readAllowList())
        guard let (item, list) = read(pasteboard), let repaired = adding(entry, to: list),
              write(repaired, item: item, to: pasteboard) else { return false }
        announce()
        return true
    }

    /// The list and the pasteboard item that holds it.
    static func read(_ pasteboard: Pasteboard) -> (item: PasteboardItemID, list: [[String: Any]])? {
        var count = 0
        var item: PasteboardItemID?
        var data: CFData?
        guard PasteboardGetItemCount(pasteboard, &count) == noErr, count > 0,
              PasteboardGetItemIdentifier(pasteboard, 1, &item) == noErr, let item,
              PasteboardCopyItemFlavorData(pasteboard, item, flavor as CFString, &data) == noErr, let data,
              let list = decode(data as Data) else { return nil }
        return (item, list)
    }

    /// Replaces the list, in the same item HIToolbox uses.
    static func write(_ list: [[String: Any]], item: PasteboardItemID, to pasteboard: Pasteboard) -> Bool {
        guard let data = encode(list), PasteboardClear(pasteboard) == noErr else { return false }
        return PasteboardPutItemFlavor(pasteboard, item, flavor as CFString, data as CFData,
                                       PasteboardFlavorFlags(rawValue: 0)) == noErr
    }

    /// The order matters: the first makes each process drop the enabled sources it remembers, the
    /// second makes the input menu build its list from the new ones.
    static func announce() {
        let center = DistributedNotificationCenter.default()
        for name in [InputSourceManager.enabledSourcesChanged, enabledKeyboardSourcesChanged] {
            center.postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }
}
