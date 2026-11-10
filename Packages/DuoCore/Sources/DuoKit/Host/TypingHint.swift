import DuoCore
import Foundation

/// The keys a hand presses to type a practice sentence on a US keyboard with 두벌식, then the flip
/// key, timed for onboarding 써보기's keyboard hint. Only the key sequence and its timing live here;
/// the host app draws the keyboard and the hands.
public enum TypingHint {
    /// A finger: hand (`L`/`R`) and number from the thumb (1) to the little finger (5).
    public enum Finger: String, CaseIterable, Sendable {
        case l1 = "L1", l2 = "L2", l3 = "L3", l4 = "L4", l5 = "L5"
        case r1 = "R1", r2 = "R2", r3 = "R3", r4 = "R4", r5 = "R5"

        public var isLeft: Bool { rawValue.hasPrefix("L") }
        public var isThumb: Bool { self == .l1 || self == .r1 }
    }

    /// One key held down by one finger. Key ids: the unshifted character for character keys
    /// (`a`, `1`, `;`), or a name (`space`, `lshift`, `rshift`, `caps`, `rcmd`, `roption`).
    public struct Press: Hashable, Sendable {
        public var key: String
        public var finger: Finger

        public init(key: String, finger: Finger) {
            self.key = key
            self.finger = finger
        }
    }

    /// Keys pressed together (a letter and Shift), and how much of the sentence is typed after them.
    public struct Step: Hashable, Sendable {
        public var chord: [Press]
        /// Characters of the sentence complete once this chord is pressed.
        public var typedCount: Int
        /// The flip key: the hint calls it out and the sentence shows the flipped word.
        public var isFlip: Bool

        public init(chord: [Press], typedCount: Int, isFlip: Bool = false) {
            self.chord = chord
            self.typedCount = typedCount
            self.isFlip = isFlip
        }
    }

    /// Touch typing: which finger presses each key.
    static let fingerOfKey: [String: Finger] = {
        let keys: [Finger: String] = [
            .l5: "` 1 tab q caps a lshift z fn control", .l4: "2 w s x option", .l3: "3 e d c", .l2: "4 5 r t f g v b",
            .r2: "6 7 y u h j n m", .r3: "8 i k ,", .r4: "9 o l .", .r5: "0 - = delete p [ ] \\ ; ' return / rshift",
            .l1: "lcmd", .r1: "space rcmd roption",
        ]
        var map: [String: Finger] = [:]
        for (finger, list) in keys { for key in list.split(separator: " ") { map[String(key)] = finger } }
        return map
    }()

    /// The unshifted key for each shifted symbol.
    static let baseOfShifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// The chord for one Latin character as typed on the keyboard, or nil if no key types it. Shift
    /// is pressed by the little finger of the other hand.
    public static func chord(latin c: Character) -> [Press]? {
        if c == " " { return [Press(key: "space", finger: .r1)] }
        var base = c
        var shift = false
        if let unshifted = baseOfShifted[c] {
            base = unshifted
            shift = true
        } else if c.isUppercase, let lower = c.lowercased().first {
            base = lower
            shift = true
        }
        guard let finger = fingerOfKey[String(base)] else { return nil }
        var chord = [Press(key: String(base), finger: finger)]
        if shift {
            chord.append(finger.isLeft ? Press(key: "rshift", finger: .r5) : Press(key: "lshift", finger: .l5))
        }
        return chord
    }

    /// The chords that press `flipKey` once. ⇧ twice is two chords.
    public static func flipChords(_ flipKey: FlipKey) -> [[Press]] {
        switch flipKey {
        case .rightCommand: [[Press(key: "rcmd", finger: .r1)]]
        case .rightOption: [[Press(key: "roption", finger: .r1)]]
        case .doubleShift: [[Press(key: "lshift", finger: .l5)], [Press(key: "lshift", finger: .l5)]]
        case .shiftSpace: [[Press(key: "lshift", finger: .l5), Press(key: "space", finger: .r1)]]
        case .capsLock: [[Press(key: "caps", finger: .l5)]]
        }
    }

    /// The steps that type `text` (Hangul through 두벌식, the rest as is), then press `flipKey`
    /// if given. Characters no key types are skipped.
    public static func steps(typing text: String, thenFlip flipKey: FlipKey? = nil) -> [Step] {
        var steps: [Step] = []
        for (index, character) in text.enumerated() {
            let latin: [Character]
            if Jamo.isHangul(character), let keys = DubeolsikLayout.keystrokes(forHangul: String(character)) {
                latin = keys.map(\.latin)
            } else {
                latin = [character]
            }
            let chords = latin.compactMap(chord(latin:))
            for (k, chord) in chords.enumerated() {
                steps.append(Step(chord: chord, typedCount: k == chords.count - 1 ? index + 1 : index))
            }
        }
        if let flipKey {
            let count = text.count
            steps += flipChords(flipKey).map { Step(chord: $0, typedCount: count, isFlip: true) }
        }
        return steps
    }

    /// When each step's keys go down and come back up, looping every `duration` seconds.
    public struct Timeline: Sendable {
        public struct Event: Sendable {
            /// The finger starts moving to the key.
            public var start: Double
            /// The key goes down.
            public var down: Double
            /// The key comes back up and the finger returns home.
            public var up: Double
        }

        public let steps: [Step]
        public let events: [Event]
        /// One loop: a pause, the steps, and a hold on the finished sentence.
        public let duration: Double

        static let leadIn = 0.6
        static let hold = 1.8

        public init(steps: [Step]) {
            self.steps = steps
            var events: [Event] = []
            var t = Self.leadIn
            for (i, step) in steps.enumerated() {
                let previousWasFlip = i > 0 && steps[i - 1].isFlip
                if step.isFlip && !previousWasFlip { t += 0.7 }
                let move = step.isFlip ? 0.16 : 0.09
                let press = step.isFlip ? 0.3 : 0.11
                events.append(Event(start: t, down: t + move, up: t + move + press))
                t += move + press
                if step.isFlip {
                    // ⇧ twice: the second tap follows quickly; the last flip stays called out.
                    t += i + 1 < steps.count && steps[i + 1].isFlip ? 0.08 : 1.2
                } else if step.chord.contains(where: { $0.key == "space" }) {
                    t += 0.16
                } else {
                    // A steady but uneven rhythm, the same on every loop.
                    t += 0.05 + Double((i * 37) % 5) * 0.02
                }
            }
            self.events = events
            duration = t + Self.hold
        }

        /// The time within the loop.
        public func loopTime(_ elapsed: Double) -> Double {
            duration > 0 ? elapsed.truncatingRemainder(dividingBy: duration) : 0
        }

        /// The step whose keys are down at `t`, if any.
        public func stepDown(at t: Double) -> Int? {
            events.firstIndex { $0.down <= t && t < $0.up }
        }

        /// Characters of the sentence typed at `t`, and whether the flip key has been pressed.
        public func progress(at t: Double) -> (typed: Int, flipped: Bool) {
            guard let last = events.lastIndex(where: { $0.down <= t }) else { return (0, false) }
            return (steps[last].typedCount, steps[...last].contains(where: \.isFlip))
        }
    }
}
