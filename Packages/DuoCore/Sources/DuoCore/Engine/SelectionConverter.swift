/// "선택한 텍스트 한↔A 변환": Hangul runs → their 두벌식 keys, Latin runs → Hangul (ux-spec §5.2).
///
/// The text is split into script runs. Each Hangul run (syllables and compatibility jamo) becomes
/// the keys a 두벌식 typist presses for it (`안녕` → `dkssud`), each Latin-letter run becomes the
/// Hangul those keys type (`dkssud` → `안녕`), and everything else (spaces, digits, punctuation,
/// emoji) is kept. Converting twice returns the original for text typed on 두벌식.
public enum SelectionConverter {
    /// Selections longer than this many characters are left unchanged.
    public static let maxLength = 2000

    /// The converted text, or `text` itself when it is longer than ``maxLength``.
    public static func convert(_ text: String) -> String {
        guard text.count <= maxLength else { return text }
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var run = ""
        var runScript: Script?

        func flush() {
            guard let script = runScript, !run.isEmpty else { return }
            switch script {
            case .latin: out += HangulAutomaton.hangul(fromLatin: run)
            case .hangul: out += keys(forHangul: run)
            }
            run = ""
            runScript = nil
        }

        for ch in text {
            let script = Script(ch)
            if script != runScript { flush() }
            if let script {
                runScript = script
                run.append(ch)
            } else {
                out.append(ch)
            }
        }
        flush()
        return out
    }

    /// Whether `convert` would change `text` (the menu item is disabled otherwise).
    public static func canConvert(_ text: String) -> Bool {
        text.count <= maxLength && text.contains { Script($0) != nil }
    }

    private enum Script {
        case latin, hangul

        init?(_ ch: Character) {
            if ch.isASCII, ch.isLetter {
                self = .latin
            } else if Jamo.isHangul(ch) {
                self = .hangul
            } else {
                return nil
            }
        }
    }

    /// Keys for a Hangul run; a character without a 두벌식 key sequence (archaic jamo) is kept.
    private static func keys(forHangul run: String) -> String {
        if let ks = DubeolsikLayout.keystrokes(forHangul: run) { return ks.latinString }
        return run.map { ch in
            DubeolsikLayout.keystrokes(forHangul: String(ch))?.latinString ?? String(ch)
        }.joined()
    }
}
