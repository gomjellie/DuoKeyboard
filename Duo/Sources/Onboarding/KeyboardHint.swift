import DuoCore
import DuoKit
import SwiftUI

/// 써보기's hint card: a keyboard and two hands play the keys of the first unfinished task, next to
/// the sentence they type. The drawing follows the download page's demo (Tools/dist/demo.js).
/// It also coaches the flip key: a real press lights the key on the drawing and is checked, and
/// other keys are offered when none comes (critique P2).
struct TypingHintCard: View {
    let progress: PracticeProgress
    var coach: FlipKeyCoachModel?

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.duoSnapshotMode) private var snapshot
    @State private var start = Date()

    var body: some View {
        let flipKey = app.settings.value.flipKey
        let task = HintTask(progress: progress)
        let timeline = TypingHint.Timeline(steps: task.steps(flipKey: flipKey))
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if task == .done || reduceMotion || snapshot {
                    content(task: task, timeline: timeline, flipKey: flipKey,
                            at: Self.stillTime(task: task, timeline: timeline, snapshot: snapshot))
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 40)) { context in
                        content(task: task, timeline: timeline, flipKey: flipKey,
                                at: timeline.loopTime(context.date.timeIntervalSince(start)))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let coach, coach.offersAlternatives && !coach.detected {
                Divider()
                Text("이 키보드에서 누르기 어렵다면 다른 키를 골라 보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                FlipKeyPicker(selection: app.settings.binding(\.flipKey), compact: true)
            }
        }
        .duoCard(padding: 14)
        .onChange(of: task) { start = Date() }
        .onChange(of: flipKey) { start = Date() }
        // The coach waits for the flip tasks, so other keys are not offered while the user types the first sentences.
        .onChange(of: task.flipsWord, initial: true) { _, flips in if flips { coach?.start() } }
        .onDisappear { coach?.stop() }
        .onChange(of: app.settings.value) { _, settings in coach?.apply(settings) }
    }

    private func content(task: HintTask, timeline: TypingHint.Timeline, flipKey: FlipKey, at t: Double) -> some View {
        let progress = timeline.progress(at: t)
        let pressed = coach?.flash == true ? Set(TypingHint.flipChords(flipKey).flatMap { $0.map(\.key) }) : []
        return HStack(spacing: 16) {
            ZStack {
                KeyboardBoard().equatable()
                KeyboardMotion(timeline: timeline, time: t, callout: flipKey.hintCallout, realPress: pressed)
            }
            .frame(width: Self.keyboardWidth, height: Self.keyboardWidth / KeyboardGeometry.aspectRatio)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.headline)
                if task != .done {
                    task.sentence(typed: progress.typed, flipped: progress.flipped)
                        .font(.system(size: 17, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityLabel(Text(verbatim: task.flippedText ?? task.text))
                }
                Text(task.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if coach?.detected == true {
                    Label("잘 눌렸어요!", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else if task.flipsWord {
                    Text(flipKey.instruction)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    static let keyboardWidth: CGFloat = 272

    /// Without motion: the sentence typed and the flip key down. Snapshots catch a letter mid-press.
    static func stillTime(task: HintTask, timeline: TypingHint.Timeline, snapshot: Bool) -> Double {
        guard let last = timeline.events.last else { return 0 }
        if let flip = timeline.steps.lastIndex(where: \.isFlip) { return timeline.events[flip].down + 0.01 }
        if snapshot { return timeline.events[timeline.events.count / 3].down + 0.01 }
        return last.up + 0.5
    }
}

/// The practice task the hint shows: the first one not done yet.
enum HintTask: Equatable {
    case greeting, numbers, flipWhileTyping, flipLastWord, done

    init(progress: PracticeProgress) {
        self = !progress.greeting ? .greeting : !progress.numbers ? .numbers
            : !progress.flippedWhileTyping ? .flipWhileTyping : !progress.flippedLastWord ? .flipLastWord : .done
    }

    /// What the hand types. 해 and go are the same two keys.
    var text: String {
        switch self {
        case .greeting: "안녕하세요 Duo를 써봐요"
        case .numbers: "macOS 26 업데이트"
        case .flipWhileTyping: "이건 해"
        case .flipLastWord: "이건 해 "
        case .done: ""
        }
    }

    /// The sentence after the flip key.
    var flippedText: String? {
        switch self {
        case .flipWhileTyping: "이건 go"
        case .flipLastWord: "이건 go "
        default: nil
        }
    }

    /// The task asks for the flip key.
    var flipsWord: Bool { flippedText != nil }

    func steps(flipKey: FlipKey) -> [TypingHint.Step] {
        self == .done ? [] : TypingHint.steps(typing: text, thenFlip: flippedText == nil ? nil : flipKey)
    }

    var title: LocalizedStringKey {
        switch self {
        case .greeting, .numbers: "따라 쳐 보세요"
        case .flipWhileTyping: "쓰는 중에 바꿔 보세요"
        case .flipLastWord: "Space 다음에 바꿔 보세요"
        case .done: "다 해냈어요"
        }
    }

    var note: LocalizedStringKey {
        switch self {
        case .greeting, .numbers: "한/영 키는 누르지 않아도 돼요."
        case .flipWhileTyping: "해로 나오면 다 치기 전에 바꾸기 키를 눌러요."
        case .flipLastWord: "Space를 누른 다음에 바꾸기 키를 눌러도 바뀌어요."
        case .done: "계속을 눌러 마무리하세요."
        }
    }

    /// Typed characters in full ink and the rest faint; the last word in its language's colour,
    /// underlined while it is still being typed.
    func sentence(typed: Int, flipped: Bool) -> Text {
        let shown = flipped ? (flippedText ?? text) : text
        let characters = Array(shown)
        let done = flipped ? characters.count : min(typed, characters.count)
        let words = shown.trimmingCharacters(in: .whitespaces)
        let lastWordStart = words.lastIndex(of: " ").map { words.distance(from: words.startIndex, to: $0) + 1 } ?? 0
        let isFlipTask = flippedText != nil
        var result = Text(verbatim: "")
        for (i, character) in characters.enumerated() {
            var piece = Text(verbatim: String(character))
            if i >= done {
                piece = piece.foregroundStyle(.tertiary)
            } else if isFlipTask && i >= lastWordStart && character != " " {
                piece = piece.foregroundStyle(flipped ? DuoStyle.english : DuoStyle.korean)
                if self == .flipWhileTyping && !flipped { piece = piece.underline() }
            }
            result = result + piece
        }
        return result
    }
}

extension FlipKey {
    /// The call-out over the flip key while the hint presses it.
    var hintCallout: String {
        switch self {
        case .rightCommand: String(localized: "오른쪽 ⌘ 톡!")
        case .rightOption: String(localized: "오른쪽 ⌥ 톡!")
        case .doubleShift: String(localized: "⇧ 두 번!")
        case .shiftSpace: "⇧ + Space"
        case .capsLock: String(localized: "Caps Lock 톡!")
        }
    }
}

// MARK: - Drawing

/// Keys and hands in the demo's units: a key is 64 wide, the board 956 × 348.
enum KeyboardGeometry {
    static let unit: CGFloat = 64
    static let pad: CGFloat = 4
    /// The board plus room for the hands; they fade out at the bottom edge.
    static let viewBox = CGRect(x: -20, y: -20, width: 968, height: 372)
    static let board = CGRect(x: -14, y: -14, width: 956, height: 348)
    static var aspectRatio: CGFloat { viewBox.width / viewBox.height }

    static let rows = [
        "` 1 2 3 4 5 6 7 8 9 0 - = delete:1.5",
        "tab:1.5 q w e r t y u i o p [ ] \\",
        "caps:1.75 a s d f g h j k l ; ' return:1.75",
        "lshift:2.25 z x c v b n m , . / rshift:2.25",
        "fn control option lcmd:1.25 space:5 rcmd:1.25 roption left updown right",
    ]
    static let symbols: [String: String] = [
        "lshift": "⇧", "rshift": "⇧", "control": "⌃", "option": "⌥", "roption": "⌥", "lcmd": "⌘", "rcmd": "⌘",
        "caps": "⇪", "left": "◀", "updown": "▲▼", "right": "▶", "fn": "fn", "tab": "⇥", "return": "↩", "delete": "⌫",
    ]

    struct Key {
        let id: String
        let rect: CGRect
        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
        var cap: CGRect { rect.insetBy(dx: pad, dy: pad) }
    }

    static let keys: [Key] = {
        var keys: [Key] = []
        for (r, row) in rows.enumerated() {
            var x: CGFloat = 0
            for spec in row.split(separator: " ") {
                let parts = spec.split(separator: ":")
                let width = (parts.count > 1 ? CGFloat(Double(parts[1]) ?? 1) : 1) * unit
                keys.append(Key(id: String(parts[0]), rect: CGRect(x: x, y: CGFloat(r) * unit, width: width, height: unit)))
                x += width
            }
        }
        return keys
    }()
    static let keyByID: [String: Key] = Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })

    static func center(_ id: String) -> CGPoint { keyByID[id]?.center ?? .zero }

    struct FingerShape {
        let home: CGPoint
        let base: CGPoint
        let width: CGFloat
    }

    struct HandShape {
        let fingers: [TypingHint.Finger]
        let palm: [TypingHint.Finger]
        let wrist: [CGPoint]
    }

    static let fingers: [TypingHint.Finger: FingerShape] = hands.fingers
    static let handShapes: [HandShape] = hands.shapes

    private static let hands: (fingers: [TypingHint.Finger: FingerShape], shapes: [HandShape]) = {
        typealias F = TypingHint.Finger
        let spec: [F: (home: String, length: CGFloat, width: CGFloat)] = [
            .l5: ("a", 96, 29), .l4: ("s", 114, 33), .l3: ("d", 122, 35), .l2: ("f", 112, 35),
            .r2: ("j", 112, 35), .r3: ("k", 122, 35), .r4: ("l", 114, 33), .r5: (";", 96, 29),
        ]
        var fingers: [F: FingerShape] = [:]
        var shapes: [HandShape] = []
        for left in [true, false] {
            let order: [F] = left ? [.l5, .l4, .l3, .l2] : [.r2, .r3, .r4, .r5]
            let centerX = order.map { center(spec[$0]!.home).x }.reduce(0, +) / 4 + (left ? 14 : -14)
            for f in order {
                let tip = center(spec[f]!.home)
                fingers[f] = FingerShape(home: tip, base: CGPoint(x: tip.x + (centerX - tip.x) * 0.08, y: tip.y + spec[f]!.length),
                                         width: spec[f]!.width)
            }
            let inward: CGFloat = left ? 1 : -1
            let index = fingers[left ? .l2 : .r2]!
            let thumbBase = CGPoint(x: index.base.x + 2 * inward, y: index.base.y + 86)
            let space = center("space")
            let thumbHome = CGPoint(x: left ? center("f").x + 54 : center("j").x - 54, y: space.y + 4)
            let thumb: F = left ? .l1 : .r1
            fingers[thumb] = FingerShape(home: thumbHome, base: thumbBase, width: 40)
            let pinky = fingers[left ? .l5 : .r5]!
            shapes.append(HandShape(
                fingers: order + [thumb],
                palm: left ? order + [thumb] : order.reversed() + [thumb],
                wrist: [CGPoint(x: thumbBase.x - 12 * inward, y: thumbBase.y + 80),
                        CGPoint(x: pinky.base.x + 4 * inward, y: pinky.base.y + 150)]))
        }
        return (fingers, shapes)
    }()

    /// Where a fingertip is at `t`: it eases to each key it presses and back home after.
    static func tip(of finger: TypingHint.Finger, at t: Double, in timeline: TypingHint.Timeline) -> CGPoint {
        guard let shape = fingers[finger] else { return .zero }
        var last: (event: TypingHint.Timeline.Event, key: CGPoint)?
        var previous: (event: TypingHint.Timeline.Event, key: CGPoint)?
        for (i, event) in timeline.events.enumerated() where event.start <= t {
            if let press = timeline.steps[i].chord.first(where: { $0.finger == finger }) {
                previous = last
                last = (event, center(press.key))
            }
        }
        func returning(_ press: (event: TypingHint.Timeline.Event, key: CGPoint), at time: Double) -> CGPoint {
            lerp(press.key, shape.home, ease((time - press.event.up) / 0.14))
        }
        guard let last else { return shape.home }
        if t > last.event.up { return returning(last, at: t) }
        let from = previous.map { returning($0, at: last.event.start) } ?? shape.home
        return lerp(from, last.key, ease((t - last.event.start) / (last.event.down - last.event.start)))
    }

    private static func ease(_ x: Double) -> CGFloat {
        let p = CGFloat(min(max(x, 0), 1))
        return 1 - (1 - p) * (1 - p) * (1 - p)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }
}

/// Light and dark colours, as on the download page.
struct KeyboardPalette {
    let board, boardEdge, key, keyEdge, keyText, jamo, handFill, handLine, nail: Color
    let handOpacity: Double

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            board = Color(red: 0.11, green: 0.11, blue: 0.12); boardEdge = Color(white: 0.19)
            key = Color(white: 0.18); keyEdge = Color(white: 0.25); keyText = Color(white: 0.9)
            jamo = Color(red: 1, green: 0.66, blue: 0.37)
            handFill = Color(red: 0.29, green: 0.32, blue: 0.36); handLine = Color(red: 0.67, green: 0.7, blue: 0.77)
            nail = Color(red: 0.43, green: 0.45, blue: 0.51); handOpacity = 0.62
        } else {
            board = Color(red: 0.87, green: 0.88, blue: 0.91); boardEdge = Color(red: 0.8, green: 0.82, blue: 0.85)
            key = .white; keyEdge = Color(red: 0.78, green: 0.8, blue: 0.83); keyText = Color(white: 0.23)
            jamo = Color(red: 0.71, green: 0.33, blue: 0.04)
            handFill = Color(red: 0.92, green: 0.93, blue: 0.96); handLine = Color(red: 0.4, green: 0.45, blue: 0.54)
            nail = .white; handOpacity = 0.82
        }
    }
}

extension GraphicsContext {
    /// Maps the demo's units onto `size`.
    fileprivate mutating func useKeyboardUnits(_ size: CGSize) {
        let scale = size.width / KeyboardGeometry.viewBox.width
        scaleBy(x: scale, y: scale)
        translateBy(x: -KeyboardGeometry.viewBox.minX, y: -KeyboardGeometry.viewBox.minY)
    }

    fileprivate func drawKey(_ key: KeyboardGeometry.Key, palette: KeyboardPalette, fill: Color? = nil) {
        let cap = Path(roundedRect: key.cap, cornerRadius: 9)
        self.fill(cap, with: .color(fill ?? palette.key))
        stroke(cap, with: .color(palette.keyEdge), lineWidth: 1.5)
        let inner = key.cap.insetBy(dx: 9, dy: 6)
        if key.id.count == 1, let jamo = DubeolsikLayout.jamoForKey[Character(key.id)] {
            draw(Text(verbatim: key.id.uppercased()).font(.system(size: 22, weight: .medium)).foregroundStyle(palette.keyText),
                 at: CGPoint(x: inner.minX, y: inner.minY), anchor: .topLeading)
            draw(Text(verbatim: String(jamo)).font(.system(size: 19, weight: .medium)).foregroundStyle(palette.jamo),
                 at: CGPoint(x: inner.maxX, y: inner.maxY), anchor: .bottomTrailing)
        } else if let symbol = KeyboardGeometry.symbols[key.id] {
            draw(Text(verbatim: symbol).font(.system(size: 19)).foregroundStyle(palette.keyText.opacity(0.75)),
                 at: key.center, anchor: .center)
        } else if key.id != "space" {
            draw(Text(verbatim: key.id).font(.system(size: 22, weight: .medium)).foregroundStyle(palette.keyText),
                 at: key.center, anchor: .center)
        }
    }
}

/// The board and every key at rest. Equatable, so it is not redrawn on every animation frame.
private struct KeyboardBoard: View, @MainActor Equatable {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = KeyboardPalette(colorScheme)
        Canvas { context, size in
            context.useKeyboardUnits(size)
            let board = Path(roundedRect: KeyboardGeometry.board, cornerRadius: 24)
            context.fill(board, with: .color(palette.board))
            context.stroke(board, with: .color(palette.boardEdge), lineWidth: 1.5)
            for key in KeyboardGeometry.keys { context.drawKey(key, palette: palette) }
        }
    }

    static func == (_: Self, _: Self) -> Bool { true }
}

/// What moves: pressed keys, the hands, and the call-out over the flip key.
private struct KeyboardMotion: View {
    let timeline: TypingHint.Timeline
    let time: Double
    let callout: String
    /// Keys the user is pressing on the real keyboard.
    var realPress: Set<String> = []

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = KeyboardPalette(colorScheme)
        Canvas { context, size in
            context.useKeyboardUnits(size)
            let down = timeline.stepDown(at: time)
            let pressed = (down.map { timeline.steps[$0].chord.map(\.key) } ?? []) + realPress.sorted()
            for id in pressed {
                guard let key = KeyboardGeometry.keyByID[id] else { continue }
                var keyContext = context
                keyContext.translateBy(x: 0, y: 1.5)
                keyContext.drawKey(key, palette: palette, fill: Color.accentColor.opacity(0.3).blendedOver(palette.key))
            }
            drawHands(in: context, palette: palette)
            for id in pressed {
                guard let key = KeyboardGeometry.keyByID[id] else { continue }
                context.stroke(Path(roundedRect: key.cap.insetBy(dx: -2, dy: -2), cornerRadius: 11),
                               with: .color(.accentColor), lineWidth: 4)
            }
            if let flip = calloutKey() { drawCallout(over: flip, in: context) }
        }
    }

    /// The flip key while its call-out shows: from the press until a moment after the last flip.
    private func calloutKey() -> KeyboardGeometry.Key? {
        guard let first = timeline.steps.firstIndex(where: \.isFlip),
              let last = timeline.steps.lastIndex(where: \.isFlip),
              timeline.events[first].down <= time, time < timeline.events[last].up + 1.1 else { return nil }
        let keys = timeline.steps[first].chord.map(\.key)
        return KeyboardGeometry.keyByID[keys.first { $0 != "space" } ?? keys[0]]
    }

    private func drawCallout(over key: KeyboardGeometry.Key, in context: GraphicsContext) {
        let label = context.resolve(Text(verbatim: callout).font(.system(size: 30, weight: .bold)).foregroundStyle(.white))
        let size = label.measure(in: CGSize(width: 600, height: 100))
        let width = size.width + 36
        let bubble = CGRect(x: key.rect.midX - width / 2, y: key.rect.minY - 56, width: width, height: 46)
            .offsetBy(dx: min(0, KeyboardGeometry.board.maxX - 6 - (key.rect.midX + width / 2)), dy: 0)
        var shape = Path(roundedRect: bubble, cornerRadius: 23)
        shape.move(to: CGPoint(x: key.rect.midX - 10, y: bubble.maxY - 1))
        shape.addLine(to: CGPoint(x: key.rect.midX, y: bubble.maxY + 11))
        shape.addLine(to: CGPoint(x: key.rect.midX + 10, y: bubble.maxY - 1))
        shape.closeSubpath()
        context.fill(shape, with: .color(.accentColor))
        context.draw(label, at: CGPoint(x: bubble.midX, y: bubble.midY), anchor: .center)
    }

    private func drawHands(in context: GraphicsContext, palette: KeyboardPalette) {
        var hands = context
        hands.opacity = palette.handOpacity
        hands.addFilter(.shadow(color: .black.opacity(0.18), radius: 5, y: 5))
        hands.drawLayer { layer in
            var tips: [TypingHint.Finger: CGPoint] = [:]
            for finger in TypingHint.Finger.allCases {
                tips[finger] = KeyboardGeometry.tip(of: finger, at: time, in: timeline)
            }
            for shape in KeyboardGeometry.handShapes {
                // The hand follows its fingers a little.
                let moving = shape.fingers.filter { !$0.isThumb }
                let dx = moving.map { tips[$0]!.x - KeyboardGeometry.fingers[$0]!.home.x }.reduce(0, +) / CGFloat(moving.count) * 0.2
                let dy = moving.map { tips[$0]!.y - KeyboardGeometry.fingers[$0]!.home.y }.reduce(0, +) / CGFloat(moving.count) * 0.2
                func base(_ f: TypingHint.Finger) -> CGPoint {
                    let b = KeyboardGeometry.fingers[f]!.base
                    return CGPoint(x: b.x + dx, y: b.y + dy)
                }
                var palm = Path()
                palm.addLines(shape.palm.map(base) + shape.wrist.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
                palm.closeSubpath()
                let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
                for (color, extra) in [(palette.handLine, CGFloat(5)), (palette.handFill, 0)] {
                    layer.fill(palm, with: .color(color))
                    layer.stroke(palm, with: .color(color), style: StrokeStyle(lineWidth: 26 + extra * 1.2, lineCap: .round, lineJoin: .round))
                    for f in shape.fingers {
                        var line = Path()
                        line.move(to: base(f))
                        line.addLine(to: tips[f]!)
                        var style = round
                        style.lineWidth = KeyboardGeometry.fingers[f]!.width + extra
                        layer.stroke(line, with: .color(color), style: style)
                    }
                }
                for f in shape.fingers {
                    let tip = tips[f]!
                    let b = base(f)
                    let width = KeyboardGeometry.fingers[f]!.width
                    let length = max(hypot(b.x - tip.x, b.y - tip.y), 1)
                    let ux = (b.x - tip.x) / length
                    let uy = (b.y - tip.y) / length
                    var nail = layer
                    nail.translateBy(x: tip.x + ux * width * 0.2, y: tip.y + uy * width * 0.2)
                    nail.rotate(by: .radians(atan2(uy, ux) - .pi / 2))
                    nail.fill(Path(ellipseIn: CGRect(x: -width * 0.26, y: -width * 0.33, width: width * 0.52, height: width * 0.66)),
                              with: .color(palette.nail))
                }
            }
            // Fade the forearms out towards the bottom edge.
            layer.blendMode = .destinationOut
            let box = KeyboardGeometry.viewBox
            layer.fill(Path(CGRect(x: box.minX - 40, y: 280, width: box.width + 80, height: box.maxY + 80 - 280)),
                       with: .linearGradient(Gradient(colors: [.clear, .black]), startPoint: CGPoint(x: 0, y: 280),
                                             endPoint: CGPoint(x: 0, y: box.maxY - 16)))
        }
    }
}

extension Color {
    /// This colour drawn over `background`, as an opaque colour (a pressed key must hide its label).
    fileprivate func blendedOver(_ background: Color) -> Color {
        let top = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let bottom = NSColor(background).usingColorSpace(.sRGB) ?? .white
        let a = top.alphaComponent
        return Color(red: top.redComponent * a + bottom.redComponent * (1 - a),
                     green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                     blue: top.blueComponent * a + bottom.blueComponent * (1 - a))
    }
}
