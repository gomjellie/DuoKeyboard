import AppKit
import DuoKit

/// The client app's on-screen windows, for checking that a caret rect belongs to them.
///
/// Window bounds need no Screen Recording permission (only titles do). The list is cached briefly:
/// the HUD asks on every show and update, and windows do not move between two keystrokes.
@MainActor
enum ClientWindows {
    private static var cache: (bundleIdentifier: String, time: TimeInterval, frames: [CGRect])?
    private static let cacheLifetime: TimeInterval = 0.5

    /// Frames in Cocoa global coordinates; empty when the app or its windows are unknown.
    static func frames(ofApp bundleIdentifier: String) -> [CGRect] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cache, cache.bundleIdentifier == bundleIdentifier, now - cache.time < cacheLifetime {
            return cache.frames
        }
        let frames = read(bundleIdentifier)
        cache = (bundleIdentifier, now, frames)
        return frames
    }

    private static func read(_ bundleIdentifier: String) -> [CGRect] {
        guard !bundleIdentifier.isEmpty, let primary = NSScreen.screens.first else { return [] }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map(\.processIdentifier))
        guard !pids.isEmpty,
              // Desktop elements stay in: Finder's desktop window holds the icon-rename field.
              let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            return HUDGeometry.cocoaRect(fromWindowBounds: rect, primaryHeight: primary.frame.height)
        }
    }
}
