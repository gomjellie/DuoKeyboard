import AppKit
import DuoKit

// DuoHarness — permission-free end-to-end test driver for the Duo input method.
//
// 1. Selects the Duo input source and focuses an NSTextView in its own window.
// 2. For each case, posts the key script to the input method's DEBUG-only injection hook, which feeds
//    the keys to the live IMK controller bound to *this* text view. Marked text and commits therefore
//    travel through the real IMK → NSTextInputClient path.
// 3. Compares the resulting text with the expectation and prints a JSON report.
//
// Usage: DuoHarness [--keep-source] [--snapshot <dir>] (<cases-file> | -e "keys" ["keys"...])
//   cases file (JSON): [{"name": "...", "keys": "dkssud{space}", "expect": "안녕 ", "expectMarked": ""}]
//   Key DSL: see DuoKit.KeyScript (`{click}` injects a mouse-down, `{rcmd}` a right-⌘ tap with device bits).
//   Exit status: 0 all passed, 1 a case failed or the IME never answered, 2 bad arguments.

struct TestCase: Codable {
    var name: String
    var keys: String
    var expect: String?
    var expectMarked: String?
}

struct CaseResult: Codable {
    var name: String
    var keys: String
    var expect: String?
    var actual: String
    var marked: String
    /// Keys the IME reported as injected (`nil` when it never acknowledged).
    var handled: Int?
    var pass: Bool?
}

@MainActor
final class Harness: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 720, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 260))
    var cases: [TestCase] = []
    var keepSource = false
    var snapshotDir: String?
    var previousSource: String?
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var handledByToken: [String: Int] = [:]
    private var counter = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Duo Harness"
        window.contentView = textView
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .systemFont(ofSize: 22)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate()

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.inkyuoh.Duo.debug.injected"), object: nil, queue: .main
        ) { [weak self] note in
            let token = note.userInfo?["token"] as? String ?? ""
            let handled = note.userInfo?["handled"] as? Int
            MainActor.assumeIsolated {
                guard let self else { return }
                if let handled { self.handledByToken[token] = handled }
                self.pending.removeValue(forKey: token)?.resume()
            }
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.inkyuoh.Duo.debug.passthrough"), object: nil, queue: .main
        ) { [weak self] note in
            let token = note.userInfo?["token"] as? String ?? ""
            let json = note.userInfo?["key"] as? String ?? "{}"
            MainActor.assumeIsolated {
                if let key = try? JSONDecoder().decode(SyntheticKey.self, from: Data(json.utf8)) { self?.applyLocally(key) }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.inkyuoh.Duo.debug.passthrough.ack"), object: nil,
                    userInfo: ["token": token], deliverImmediately: true)
            }
        }

        previousSource = InputSourceManager.currentKeyboardSourceID()
        // Always re-register: it is idempotent and picks up Info.plist changes (name, icon) of a fresh install.
        let registered = InputSourceManager.register()
        log("register=\(registered)")
        InputSourceManager.enable()
        let sel = InputSourceManager.select()
        log("select=\(sel) current=\(InputSourceManager.currentKeyboardSourceID() ?? "nil")")

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            var results: [CaseResult] = []
            for c in cases { results.append(await run(c)) }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
            if let data = try? enc.encode(results), let s = String(data: data, encoding: .utf8) { print(s) }
            let failed = results.filter { $0.pass == false }
            for f in failed { log("FAIL \(f.name): expected \(f.expect.debugDescription) got \(f.actual.debugDescription)") }
            let silent = results.filter { $0.handled == nil }
            for s in silent { log("FAIL \(s.name): the input method never acknowledged the injection") }
            log("\(results.count - failed.count)/\(results.count) passed")
            if !keepSource, let prev = previousSource { InputSourceManager.select(sourceID: prev) }
            fflush(stdout)
            exit(failed.isEmpty && silent.isEmpty ? 0 : 1)
        }
    }

    func run(_ c: TestCase) async -> CaseResult {
        window.makeFirstResponder(textView)
        if !NSApp.isActive { NSApp.activate() }
        // The IME keeps per-field state (context, a leftover composition, the last commit) across
        // cases, because every case runs in this one text view. Reset it the way a user would: a
        // click (R4: commits anything pending, next word starts a sentence), then clear the field.
        _ = await inject("{click}")
        textView.string = ""
        try? await Task.sleep(for: .milliseconds(120))
        let handled = await inject(c.keys)
        try? await Task.sleep(for: .milliseconds(120))
        let marked = textView.hasMarkedText()
            ? (textView.string as NSString).substring(with: textView.markedRange()) : ""
        let actual = textView.string
        if let dir = snapshotDir { snapshot(to: "\(dir)/\(c.name).png") }
        var pass: Bool? = c.expect.map { $0 == actual }
        if let em = c.expectMarked { pass = (pass ?? true) && em == marked }
        // Leave no composition behind for the next case.
        textView.inputContext?.discardMarkedText()
        textView.unmarkText()
        return CaseResult(name: c.name, keys: c.keys, expect: c.expect, actual: actual, marked: marked,
                          handled: handled, pass: pass)
    }

    /// Posts `keys` to the IME and waits for its acknowledgement; returns the IME's handled count.
    func inject(_ keys: String) async -> Int? {
        counter += 1
        let token = "t\(counter)"
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pending[token] = cont
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.inkyuoh.Duo.debug.inject"), object: nil,
                userInfo: ["keys": keys, "token": token], deliverImmediately: true)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if let c = self.pending.removeValue(forKey: token) {
                    self.log("timeout waiting for IME ack (\(token)) — is Duo selected and built in Debug?")
                    c.resume()
                }
            }
        }
        let handled = handledByToken.removeValue(forKey: token)
        if handled == 0, KeyScript.parse(keys).contains(where: { $0.kind != .wait }) {
            // The input method injects only into this app's text view while this app is frontmost.
            log("the IME injected nothing (\(token)) — DuoHarness must be the frontmost app with its text view focused")
        }
        return handled
    }

    /// Processes a key the input method passed through, the way the app would for a physical key.
    /// (In-process synthesized events are not routed to input methods, so this hits key bindings directly.)
    func applyLocally(_ key: SyntheticKey) {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                        modifierFlags: NSEvent.ModifierFlags(rawValue: key.modifiers),
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: key.characters,
                                        charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                                        isARepeat: false, keyCode: key.keyCode) else { return }
        if NSEvent.ModifierFlags(rawValue: key.modifiers).contains(.command) {
            _ = NSApp.mainMenu?.performKeyEquivalent(with: ev)
            if key.charactersIgnoringModifiers == "a" { textView.selectAll(nil) }
            return
        }
        textView.keyDown(with: ev)
    }

    func snapshot(to path: String) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func log(_ s: String) { FileHandle.standardError.write(Data("[harness] \(s)\n".utf8)) }
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("""
        [harness] \(message)
        usage: DuoHarness [--keep-source] [--snapshot <dir>] (<cases-file> | -e "keys" ["keys"...])

        """.utf8))
    exit(2)
}

let harness = Harness()
var args = Array(CommandLine.arguments.dropFirst())
var casesPath: String?
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--keep-source":
        harness.keepSource = true
    case "--snapshot":
        guard !args.isEmpty else { usage("--snapshot needs a directory") }
        let dir = args.removeFirst()
        harness.snapshotDir = dir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    case "-e":
        guard !args.isEmpty else { usage("-e needs at least one key script") }
        harness.cases = args.enumerated().map { TestCase(name: "inline\($0.offset)", keys: $0.element) }
        args.removeAll()
    case _ where arg.hasPrefix("-NS") || arg.hasPrefix("-Apple"):
        // User-defaults arguments Xcode or LaunchServices may add (-NSDocumentRevisionsDebugMode YES).
        if !args.isEmpty, !args[0].hasPrefix("-") { args.removeFirst() }
    case _ where arg.hasPrefix("-"):
        usage("unknown option \(arg)")
    default:
        guard casesPath == nil else { usage("more than one cases file: \(arg)") }
        casesPath = arg
    }
}
if let casesPath {
    guard let data = FileManager.default.contents(atPath: casesPath) else { usage("cannot read cases file \(casesPath)") }
    do { harness.cases = try JSONDecoder().decode([TestCase].self, from: data) } catch {
        usage("bad cases file \(casesPath): \(error)")
    }
}
if harness.cases.isEmpty { usage("no cases to run") }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = harness
app.run()
