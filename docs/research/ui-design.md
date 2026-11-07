# Duo — UI 기술과 시각 디자인 명세 (macOS 26 Tahoe)

트랙: macOS 26 UI 기술 + 시각 디자인. **확인함** 표시가 붙은 내용은 모두 이 기기에서
`MacOSX27.2.sdk`(Xcode 27.2, Swift 6.4.2, macOS 26.6.2 arm64)로 확인했어요. 헤더와 `.swiftinterface`를 읽었고, `swiftc -swift-version 6
-target arm64-apple-macos26.0 -warnings-as-errors`로 컴파일했고, `swift test`를 돌렸어요. 렌더링하거나 캡처한 PNG도 직접 봤어요.
프로브 소스는 `/private/tmp/claude-501/-Users-user-orca-zlqhem/b8fa910a-9760-4366-944c-1b8329866082/scratchpad/ui-probe/`에 있어요
(버릴 파일이에요. 중요한 코드 조각은 모두 이 파일에 옮겨 두었어요).

---

## 0. 한 화면으로 보는 결정 사항

| 주제 | 결정 |
|---|---|
| 배포 대상(deployment target) | 두 타깃 모두 **macOS 26.0**. SDK가 27.2라서 macOS 27 API도 들어 있지만, 사용자는 26.6.2를 씀. **`macOS 27` API는 호출하지 않음**(`NSGlassEffectView.effectIsInteractive`, `NSViewCornerConfiguration`, `NSMenuItem.preferredImageVisibility`, …). 26.1 API는 `#available(macOS 26.1, *)` 검사로 감쌈. 해당 API는 `GlassButtonStyle.init(_:)`을 쓰는 `.buttonStyle(.glass(.clear))`와 `NSScrollEdgeEffectStyle`임. |
| HUD 유리 | **투명하고 테두리 없으며 활성화되지 않는 `NSPanel`** 안에서 SwiftUI `.glassEffect(.regular, in: .capsule)`을 씀. 캡처로 확인함: 라이트와 다크 모두에서 유리가 *패널 뒤에 있는 다른 창*의 내용을 비춤. 패널의 `contentView`로 `NSGlassEffectView`를 써도 동작함. 이것이 AppKit 대안임. |
| HUD 창 | `[.borderless, .nonactivatingPanel]`, 레벨 `CGShieldingWindowLevel()`(2147483628. 레벨 101인 메뉴와 Spotlight보다 위. rime/Squirrel과 같음), `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`, `canBecomeKey/Main = false`. `orderFrontRegardless()`로 띄움. 입력기 앱은 **절대** 활성화하지 않음. |
| HUD 배치 | 순수 함수(`HUDGeometry.place`, Swift Testing 단위 테스트 7/7 통과). IMK 캐럿 사각형에 맞춰 정렬함. 화면 아래쪽 가장자리 근처에서는 캐럿 위로 올림. `visibleFrame` 안으로 제한함. 캐럿이 있는 디스플레이를 고름. 백킹 배율(backing scale)에 맞춰 스냅함. 엉터리 사각형이 오면 숨김. |
| 호스트 앱 | 시스템 설정처럼 생긴 사이드바 `Window` 하나(`NavigationSplitView` + `Form.formStyle(.grouped)`). ⌘,도 이 창으로 다시 연결함. 제목 막대를 숨긴 온보딩 `Window`가 따로 있고, 4단계로 진행됨. 버튼은 `.glass` / `.glassProminent`. |
| 앱 아이콘 | **코드로 생성한 Icon Composer `.icon` 번들**. 폰트 윤곽선 없이 손으로 만든 SVG 도형이라 라이선스 문제가 없음. `actool`이 이를 `Assets.car` + `AppIcon.icns`로 컴파일함. XcodeGen 2.46에서는 `sources` 아래에 나열하기만 하면 됨(처음부터 끝까지 확인함). 콘셉트: 겹친 키캡 두 개. 따뜻한 색 키캡에 "가", 차가운 색 키캡에 "A". |
| 입력 소스(input source) 아이콘 | 16×16 pt **템플릿 TIFF**(16 px @72 dpi + 32 px @144 dpi 표현), 검정 + 알파, `TISIconIsTemplate = true`. Apple의 `KoreanIM`과 같은 형식임. 코드로 생성함. |
| TCC 없이 하는 시각 QA | `ImageRenderer`는 **유리 뷰를 통째로 빼먹음**. 그래서 스냅샷용 대체물을 씀. `cacheDisplay`는 창을 화면 밖에 두고 순서에 넣으면(order in) Form과 컨트롤에서 동작함. **이 세션에서는 ScreenCaptureKit으로 우리 창을 캡처할 수 있었음**(`CGPreflightScreenCaptureAccess() == true`, 실제 Liquid Glass가 캡처됨). "화면 기록 권한 없음" 가정과 어긋나므로 5절 참고. `CGWindowListCreateImage`는 컴파일 시점에 *사용 불가*임. |

---

## 1. SDK로 확인한 API 목록

### 1.1 AppKit (`AppKit.framework/Headers`)

| API | 시그니처 (Swift) | 사용 가능 버전 |
|---|---|---|
| `NSGlassEffectView` | `class NSGlassEffectView: NSView { var contentView: NSView?; var cornerRadius: CGFloat; var tintColor: NSColor?; var style: NSGlassEffectView.Style }` | macOS 26.0 |
| `NSGlassEffectView.Style` | `.regular`, `.clear` | 26.0 |
| `NSGlassEffectView.effectIsInteractive` | `var effectIsInteractive: Bool` (기본값 false) | **macOS 27.0** (사용자 OS에는 없음) |
| `NSGlassEffectContainerView` | `var contentView: NSView?; var spacing: CGFloat` (기본값 0이면 합치지 않고 한데 묶어 처리함) | 26.0 |
| `NSBackgroundExtensionView` | `var contentView: NSView?; var automaticallyPlacesContentView: Bool` (기본값 true) | 26.0 |
| `NSButton.BezelStyle.glass` | `button.bezelStyle = .glass` (원시값 16) | 26.0 |
| `NSButton.tintProminence` / `NSSlider.tintProminence` | `NSTintProminence` (`.primary` …) | 26.0 |
| `NSButton`, `NSTextField`, `NSSegmentedControl`의 `borderShape` | `NSControl.BorderShape` (`.capsule` …) | 26.0 |
| `NSControl.ControlSize.extraLarge` | | 26.0 |
| `NSSlider.neutralValue` | `var neutralValue: Double` | 26.0 |
| `NSView.prefersCompactControlSizeMetrics` | `Bool` | 26.0 |
| `NSToolbarItem.style`, `.backgroundTintColor`, `.badge` (`NSItemBadge`) | | 26.0 |
| `NSSplitViewItem.automaticallyAdjustsSafeAreaInsets`, `top/bottomAlignedAccessoryViewControllers` | | 26.0 |
| `NSView` 레이아웃 영역 (`layoutGuide(for:)`, `edgeInsets(for:)`, `rect(for:)`) | `NS_REFINED_FOR_SWIFT` | 26.0 |
| `NSImage.SymbolConfiguration(variableValueMode:)`, `(colorRenderingMode:)` | | 26.0 |
| `NSScrollEdgeEffectStyle` (`.automatic`, `.soft`, `.hard`), 그리고 `NSTitlebarAccessoryViewController` / `NSSplitViewItemAccessoryViewController`의 `preferredScrollEdgeEffectStyle` | 클래스 | **26.1** |
| macOS 27 전용 | `NSViewCornerConfiguration`, `NSViewCornerRadii`, `NSView.cornerConfiguration`, NSStatusItem 확장 인터페이스, `NSMenuItem.preferredImageVisibility`, `NSSegmentedControl.role`, `NSToolbarItemGroup.role`, `NSRefreshController`, `NSTextSelectionManager`, 터치스크린 API (`NSScreen.touchCapabilities`) | **27.0**: 쓰지 않음 |

### 1.2 SwiftUI / SwiftUICore (`*.swiftmodule/arm64e-apple-macos.swiftinterface`)

모든 유리 API에는 `@available(iOS 26, macOS 26, tvOS 26, watchOS 26, *)`와 `@available(visionOS, unavailable)` 표시가 붙어 있어요.

```swift
// SwiftUICore
nonisolated func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View
public struct Glass: Equatable, Sendable {
  static var regular: Glass; static var clear: Glass; static var identity: Glass   // identity = no glass (conditional off)
  func tint(_ color: Color?) -> Glass
  func interactive(_ isEnabled: Bool = true) -> Glass
}
@MainActor struct GlassEffectContainer<Content: View>: View { init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) }
nonisolated func glassEffectID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View
@MainActor func glassEffectUnion(id: (some Hashable & Sendable)?, namespace: Namespace.ID) -> some View
struct GlassEffectTransition: Sendable { static var matchedGeometry, materialize, identity }
@MainActor func glassEffectTransition(_ transition: GlassEffectTransition) -> some View
struct ConcentricRectangle: Shape   // init(), init(corners:isUniform:), per-corner .concentric styles   (26.0, all platforms)

// SwiftUI
extension PrimitiveButtonStyle where Self == GlassButtonStyle {
  static var glass: GlassButtonStyle            // 26.0
  static func glass(_ glass: Glass) -> Self     // GlassButtonStyle.init(_:) is 26.1
}
extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle { static var glassProminent: GlassProminentButtonStyle } // 26.0
@MainActor func backgroundExtensionEffect() -> some View                       // 26.0 (incl. visionOS)
@MainActor func backgroundExtensionEffect(isEnabled: Bool) -> some View
struct ToolbarSpacer: ToolbarContent, CustomizableToolbarContent {
  init(_ sizing: SpacerSizing = .flexible, placement: ToolbarItemPlacement = .automatic)   // SpacerSizing: .flexible, .fixed   (iOS/macOS 26)
}
struct ScrollEdgeEffectStyle: Hashable, Sendable { static var automatic, hard, soft }
nonisolated func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View
nonisolated func scrollEdgeEffectHidden(_ hidden: Bool = true, for edges: Edge.Set = .all) -> some View
// Slider with neutral value + ticks (26.0)
Slider(value:in:neutralValue:enabledBounds:label:currentValueLabel:minimumValueLabel:maximumValueLabel:ticks:onEditingChanged:)
SliderTick(_ value: V) / SliderTick(_ title: LocalizedStringKey, _ value: V)
func labelIconToTitleSpacing(_ value: CGFloat) -> some View                    // 26.0
func symbolColorRenderingMode(_ mode: SymbolColorRenderingMode?)              // 26.0
// Observation (anyAppleOS 26): struct Observations<Element, Failure>: AsyncSequence — `for await v in Observations({ model.x })`
```

우리가 기대는 이전 버전 API는 다음과 같아요. `Settings`, `SettingsLink`, `openSettings`, `Window`, `.windowStyle(.hiddenTitleBar)`, `.windowResizability`,
`.defaultLaunchBehavior` / `.restorationBehavior` (15), `.toolbar(removing: .sidebarToggle)` (14), `FormStyle.grouped`, `ContentUnavailableView` (14),
`@Observable` (14), `@Entry` (매크로, 이전 OS에도 배포됨), `NSHostingView.sizingOptions` (`.minSize`, `.intrinsicContentSize`, `.maxSize`, `.preferredContentSize`, `.standardBounds`).
이 SDK에 있는 macOS 27 전용 SwiftUI 추가 기능(쓰지 않음)은 문서 API(`Document`, `DocumentReader`), 순서를 바꿀 수 있는 컨테이너, `ArrangementView`,
`ToolbarMinimizationBehavior`, `PresentationPlacement`, `TabsPickerStyle`, `BorderedTextFieldStyle` 등이에요.

1절의 모든 내용은 파일 하나(`inventory/GlassInventory.swift`, 부록 A에 옮겨 둠)에서 `-target arm64-apple-macos26.0 -warnings-as-errors`로 컴파일돼요.

---

## 2. 조합 HUD

### 2.1 동작

클라이언트 앱의 조합 문자열(marked text)에는 Duo가 가장 그럴듯하다고 본 결과가 나와요(예: `안녕`). HUD는 캐럿 바로 아래에 뜨는 작은 유리 칩이에요.
칩에는 **다른 해석**(`dkssud`), 그 해석의 언어를 나타내는 배지, 바꾸기 키(flip key)의 키캡 힌트가 나와요.
바꾸기 키를 누르면 둘이 서로 바뀌어요.

| 이벤트 | HUD 반응 |
|---|---|
| 조합 시작 (첫 키) | 키 하나짜리 단어에서는 숨긴 채로 둠. **두 번째 키 입력**부터 보여 줌. 자동 감지기가 이미 바꿨다면 바로 보여 줌. "a", "I", "ㅋ" 같은 입력에서 거슬리지 않게 하려는 것임. |
| 키 입력마다 | 텍스트가 **즉시** 바뀜. Apple 자체 후보 UI처럼 키 입력마다 애니메이션을 넣지 않음. 패널 크기를 다시 재고(`fittingSize`가 동기적으로 갱신됨, 확인함) 다시 배치함. |
| 자동 감지기가 단어 도중에 언어를 바꿈 (예: `rk` → `가`) | 배지 글리프가 SF Symbols *replace* 전환으로 바뀜(`character` ↔ `character.ko`, `.replace.downUp`). 칩이 **한 번** 살짝 맥박침: 배율 1.00→1.04→1.00, 앞쪽(leading) 기준점, 커질 때 spring 0.18 s, 가라앉을 때 0.32 s. 그동안 유리에 25 % 강조색 틴트를 더함. 소리는 없고, 패널 자체도 움직이지 않음. |
| 사용자가 바꾸기 키를 누름 | 인라인 텍스트와 칩 텍스트가 서로 바뀜. 칩 텍스트는 spring(0.28 s, bounce 0.12)과 함께 `.contentTransition(.interpolate)`을 씀. |
| 확정 (스페이스, 문장 부호, 리턴, 클릭) / Esc | **140 ms 디바운스(debounce)** 뒤에 숨김. 이어서 100 ms ease-in 페이드를 줌. 디바운스 안에 새 단어가 시작되면 HUD는 자리만 옮김. 그래서 계속 타이핑해도 깜빡이지 않음. |
| `deactivateServer`, 클라이언트 전환, 캐럿 사각형을 쓸 수 없음 | 애니메이션 없이 즉시 `orderOut`함. |
| 처음 표시 | 140 ms ease-out 알파 페이드인(동작 줄이기(Reduce Motion)에서는 80 ms). 크기 변화나 미끄러짐은 없음. |

### 2.2 구성과 치수 (포인트)

```
 ┌────────────────────────────────────────────┐  ← capsule, height 28, Liquid Glass .regular
 │ (A)  dkssud   [⇧][Space]                   │
 └────────────────────────────────────────────┘
  ↑4  ↑20 badge ↑6 gap  text 14pt medium  ↑6  keycaps 16pt-high, 10pt rounded semibold  ↑4 trailing (10 when no hint)
```

* 칩 높이 **28**. 앞쪽 여백 **4**(배지가 캡슐 안에 동심으로 들어감). 내부 간격 **6**. 뒤쪽 여백 **4**, 힌트를 숨기면 **10**.
* 배지: **20** pt 원. 영어는 `Color.blue`, 한국어는 `Color.orange`로 채움. 안에 SF Symbol `character`("A") 또는 `character.ko`("가")가 들어감. 11 pt semibold, 흰색. 시스템 색이라 다크 모드와 대비 증가(Increase Contrast)에 자동으로 맞춰짐.
* 텍스트: SF Pro 14 pt medium, `.primary`, 한 줄, `fixedSize`. 한글은 자동으로 Apple SD Gothic Neo로 대체됨.
* 키캡: SF Pro Rounded 10 pt semibold, `.secondary`. `RoundedRectangle(cornerRadius: 4, style: .continuous)`를 `primary.opacity(0.08)`로 채움(투명도 줄이기(Reduce Transparency)에서는 0.14). 최소 16×16, 가로 여백 4 pt, 키캡 사이 간격 2 pt.
* 배치: 캐럿 줄 상자에서 **5 pt** 아래. 칩의 앞쪽 가장자리는 **조합 문자열 시작점보다 8 pt 왼쪽**에 둠. `visibleFrame` 가장자리에서 **6 pt** 떨어뜨림. 패널 안쪽에는 유리 그림자와 맥박 오버슈트를 위한 **8 pt** 투명 여백이 있음.
* 창 그림자는 끔(`hasShadow = false`). 유리가 자체 그림자를 그리고, 창 그림자는 사각형으로 나오기 때문임.

### 2.3 접근성

* **동작 줄이기(Reduce Motion)** (`@Environment(\.accessibilityReduceMotion)` / `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`): 맥박도 크기 변화도 없음. 배지와 텍스트는 불투명도 크로스페이드로만 바뀜. 페이드인은 80 ms.
* **투명도 줄이기 / 대비 증가**: 시스템 유리가 알아서 맞춰짐(불투명하게 흐려지고 가장자리가 더 진해짐). 여기에 더해 키캡 채움 불투명도를 높임. `colorSchemeContrast == .increased`이면 캡슐에 1 pt `primary.opacity(0.55)` 가는 선을 그음. `out/snapshot-dark-hc.png` 스냅샷으로 확인함.
* **다크 / 라이트**: 색을 하드코딩하지 않음. 두 모드 모두 섞인 배경 위에서 캡처함(2.8절).
* **VoiceOver**: 칩은 단일 요소임. 레이블은 "English alternative" / "Korean alternative", 값은 텍스트. 키 입력마다 읽어 주지 않음. 선택 사항으로, `NSWorkspace.shared.isVoiceOverEnabled`일 때만 자동 바꾸기가 일어나면 우선순위가 낮은 `NSAccessibility.post(element:notification: .announcementRequested, userInfo: [.announcement: "…", .priority: NSAccessibilityPriorityLevel.low.rawValue])`를 보냄.

### 2.4 배치 규칙 (IMK 캐럿 사각형을 넣어 줌)

* 사각형은 `client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)`에서 얻음. 이 값은 **Cocoa 전역 좌표**(`NSScreen.screens[0]`의 왼쪽 아래가 원점, y는 위쪽)로 된 조합 문자열 시작점임. **뒤집지 않고** 그대로 넘김.
* 클라이언트가 가끔 `.zero`를 돌려줌: 이때는 숨김. 높이 0은 16 pt로 취급함. 어느 디스플레이에도 없는 사각형은 주 디스플레이 높이를 기준으로 뒤집어서 다시 시도함(왼쪽 위가 원점인 y를 돌려주는 클라이언트를 잡아냄). 그래도 없으면 숨김.
* 화면 선택에는 `frame.contains(caret.origin)`을 씀. `NSScreen.main`은 쓰지 않음(키 창의 화면이라, 클라이언트의 화면이 아닐 수 있음).
* 캐럿 **아래**를 우선함. 칩이 `visibleFrame.minY`(Dock)를 넘게 되면 **위**에 둠(`caret.maxY + 5`). x와 y를 `visibleFrame.insetBy(6)` 안으로 제한함.
* 원점을 `1/backingScaleFactor` 단위로 스냅함. 그래야 패널이 움직이는 동안에도 텍스트가 선명함.
* 업데이트마다 다시 배치함. 창 프레임은 애니메이션하지 않음(`animate: false`). NSWindow 프레임 애니메이션은 끊기고 타이핑보다 늦음.

### 2.5 코드 — 기하 계산 (순수, Sendable, 단위 테스트됨) — 확인함

```swift
import CoreGraphics

/// Pure, testable placement math for the composition HUD.
/// All rects are in Cocoa *global* screen coordinates: origin at the bottom-left of the
/// primary display (NSScreen.screens[0]), y grows upward — the space IMK returns from
/// `IMKTextInput.attributes(forCharacterIndex:lineHeightRectangle:)`.
public struct HUDScreen: Sendable, Equatable {
    public var frame: CGRect          // NSScreen.frame
    public var visibleFrame: CGRect   // NSScreen.visibleFrame (minus menu bar + Dock)
    public var scale: CGFloat         // NSScreen.backingScaleFactor
    public init(frame: CGRect, visibleFrame: CGRect, scale: CGFloat) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.scale = scale
    }
}

public struct HUDPlacement: Sendable, Equatable {
    public enum Edge: Sendable, Equatable { case below, above }
    /// Frame of the chip itself (the visible glass capsule), global coords.
    public var chipFrame: CGRect
    /// Frame for the (larger, transparent) NSPanel that hosts the chip + shadow margin.
    public var panelFrame: CGRect
    public var edge: Edge
}

public enum HUDGeometry {
    /// Vertical gap between the caret line box and the chip.
    public static let gap: CGFloat = 5
    /// Keep the chip this far from visibleFrame edges.
    public static let screenMargin: CGFloat = 6
    /// The chip's leading edge sits this far left of the caret so the text column
    /// inside the chip (after the 20pt badge + 6pt spacing + 8pt padding) visually
    /// starts near the marked-text start. Tuned for a 28pt-high chip.
    public static let leadingOutset: CGFloat = 8

    /// - Parameters:
    ///   - caret: line-height rect of the *start* of the marked text (character index 0).
    ///   - chipSize: SwiftUI fitting size of the chip.
    ///   - margin: transparent margin around the chip inside the panel (room for shadow & spring overshoot).
    ///   - screens: NSScreen.screens mapped to HUDScreen, index 0 = primary.
    /// - Returns: nil when the caret rect is unusable (hide the HUD).
    public static func place(caret rawCaret: CGRect,
                             chipSize: CGSize,
                             margin: CGFloat,
                             screens: [HUDScreen]) -> HUDPlacement? {
        guard !screens.isEmpty,
              rawCaret.origin.x.isFinite, rawCaret.origin.y.isFinite,
              !(rawCaret.origin == .zero && rawCaret.size == .zero) else { return nil }

        var caret = rawCaret
        if caret.height < 1 { caret.size.height = 16 }   // some clients return 0-height rects
        let probe = CGPoint(x: caret.minX, y: caret.midY)

        // 1. Screen that contains the caret. 2. Heuristic for clients that hand back
        // *flipped* (top-left origin) coordinates: flip around the primary display height.
        var screen = screens.first { $0.frame.contains(probe) }
        if screen == nil {
            let primaryHeight = screens[0].frame.height
            var flipped = caret
            flipped.origin.y = primaryHeight - caret.maxY
            if let s = screens.first(where: { $0.frame.contains(CGPoint(x: flipped.minX, y: flipped.midY)) }) {
                caret = flipped; screen = s
            }
        }
        // Still nowhere on any display => the client handed us garbage; hide rather than guess.
        guard let screen = screen ?? screens.first(where: { $0.frame.intersects(caret) }) else { return nil }
        let vis = screen.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)

        // Horizontal: align to caret, clamp into the visible frame.
        var x = caret.minX - leadingOutset
        x = min(max(x, vis.minX), vis.maxX - chipSize.width)

        // Vertical: prefer below the line; flip above when it would leave the visible frame.
        var edge = HUDPlacement.Edge.below
        var y = caret.minY - gap - chipSize.height
        if y < vis.minY {
            edge = .above
            y = caret.maxY + gap
        }
        y = min(max(y, vis.minY), vis.maxY - chipSize.height)

        // Snap to the backing pixel grid of the target display (crisp text, no shimmer while moving).
        func snap(_ v: CGFloat) -> CGFloat { (v * screen.scale).rounded() / screen.scale }
        let chip = CGRect(x: snap(x), y: snap(y), width: chipSize.width, height: chipSize.height)
        let panel = chip.insetBy(dx: -margin, dy: -margin)
        return HUDPlacement(chipFrame: chip, panelFrame: panel, edge: edge)
    }
}
```

Swift Testing 테스트 모음(`swift test`로 7/7 통과):

```swift
import Testing
import CoreGraphics
@testable import DuoHUDGeometry

// Primary 1512x982 @2x laptop (menu bar 33pt), external 2560x1440 @1x to the RIGHT.
let laptop = HUDScreen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                       visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), scale: 2)
let external = HUDScreen(frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                         visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1407), scale: 1)
let chip = CGSize(width: 120, height: 28)

@Suite("HUD placement")
struct HUDGeometryTests {
    @Test func placesBelowCaretAlignedToMarkedTextStart() throws {
        let caret = CGRect(x: 400, y: 500, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: 8, screens: [laptop, external]))
        #expect(p.edge == .below)
        #expect(p.chipFrame.maxY == caret.minY - HUDGeometry.gap)
        #expect(p.chipFrame.minX == caret.minX - HUDGeometry.leadingOutset)
        #expect(p.panelFrame == p.chipFrame.insetBy(dx: -8, dy: -8))
    }

    @Test func flipsAboveNearBottomEdge() throws {
        let caret = CGRect(x: 400, y: 20, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: 8, screens: [laptop]))
        #expect(p.edge == .above)
        #expect(p.chipFrame.minY == caret.maxY + HUDGeometry.gap)
    }

    @Test func clampsToRightEdgeOfVisibleFrame() throws {
        let caret = CGRect(x: 1500, y: 500, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: 8, screens: [laptop, external]))
        #expect(p.chipFrame.maxX <= laptop.visibleFrame.maxX - HUDGeometry.screenMargin)
    }

    @Test func usesTheDisplayThatContainsTheCaret() throws {
        let caret = CGRect(x: 2000.3, y: -100.2, width: 1, height: 18)   // on the external display, below y=0
        let p = try #require(HUDGeometry.place(caret: caret, chipSize: chip, margin: 8, screens: [laptop, external]))
        #expect(external.frame.contains(p.chipFrame))
        #expect(p.chipFrame.minX == p.chipFrame.minX.rounded())       // 1x display => whole points
    }

    @Test func recoversFromFlippedClientCoordinates() throws {
        // External display BELOW the primary. True caret (Cocoa) y = -500 on it; a buggy client
        // reports top-left-origin y = 982 - (-500) - 18 = 1464, which is on no display.
        let below = HUDScreen(frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), scale: 1)
        let buggy = CGRect(x: 400, y: 1464, width: 1, height: 18)
        let p = try #require(HUDGeometry.place(caret: buggy, chipSize: chip, margin: 8, screens: [laptop, below]))
        #expect(p.chipFrame.maxY == -500 - HUDGeometry.gap)
    }

    @Test func caretOnNoDisplayHides() {
        let lost = CGRect(x: -5000, y: -5000, width: 1, height: 18)
        #expect(HUDGeometry.place(caret: lost, chipSize: chip, margin: 8, screens: [laptop]) == nil)
    }

    @Test func zeroRectHides() {
        #expect(HUDGeometry.place(caret: .zero, chipSize: chip, margin: 8, screens: [laptop]) == nil)
    }
}
```

### 2.6 코드 — 뷰, 패널, 컨트롤러 (Swift 6 strict, 경고 없이 컴파일됨) — 확인함

```swift
import AppKit
import SwiftUI
import Observation

// MARK: - Model (owned by the input controller, mutated on the main actor)

public enum DuoScript: String, Sendable, Equatable {
    case hangul, latin
}

@MainActor
@Observable
public final class CompositionHUDModel {
    /// The *other* interpretation of the keys typed so far (what flipping would produce).
    public var alternative: String = ""
    /// Script of `alternative` (so the badge shows "A" while the inline text is Hangul).
    public var alternativeScript: DuoScript = .latin
    /// Key-cap glyphs for the flip key, e.g. ["⇧", "Space"] or ["⌘"] (right command tap).
    public var flipKeyCaps: [String] = ["⇧", "Space"]
    /// Bumped by the controller whenever auto-detection flips the inline language mid-word.
    public var autoFlipCount: Int = 0
    /// Bumped when the user presses the flip key (manual flip).
    public var manualFlipCount: Int = 0
    public var showsKeyHint: Bool = true

    public init() {}
}

// MARK: - SwiftUI chip

public struct CompositionHUDView: View {
    let model: CompositionHUDModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    public init(model: CompositionHUDModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 6) {
            badge
            Text(model.alternative)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.primary)
                .contentTransition(reduceMotion ? .opacity : .interpolate)
                .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12), value: model.manualFlipCount)
            if model.showsKeyHint {
                keyHint
                    .transition(.opacity)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, model.showsKeyHint ? 4 : 10)
        .frame(height: 28)
        .duoGlass(glass, in: Capsule())
        .overlay {
            // Increase Contrast: glass already gains a stronger edge; add a crisp 1px hairline anyway.
            if contrast == .increased {
                Capsule().strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
            }
        }
        .scaleEffect(pulse && !reduceMotion ? 1.04 : 1, anchor: .leading)
        .onChange(of: model.autoFlipCount) {
            guard !reduceMotion else { return }
            withAnimation(.spring(duration: 0.18, bounce: 0.4)) { pulse = true } completion: {
                withAnimation(.spring(duration: 0.32, bounce: 0.2)) { pulse = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(model.alternativeScript == .latin ? "English alternative" : "Korean alternative"))
        .accessibilityValue(Text(model.alternative))
    }

    private var glass: Glass {
        // A whisper of tint while the auto-flip pulse is active; nothing otherwise.
        pulse ? .regular.tint(Color.accentColor.opacity(0.25)) : .regular
    }

    /// 20pt circle with "A" / "가": tells the user which language the chip would give them.
    private var badge: some View {
        Image(systemName: model.alternativeScript == .latin ? "character" : "character.ko")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(model.alternativeScript == .latin ? Color.blue : Color.orange))
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
            .animation(.snappy(duration: 0.22), value: model.alternativeScript)
    }

    private var keyHint: some View {
        HStack(spacing: 2) {
            ForEach(model.flipKeyCaps, id: \.self) { cap in
                Text(cap)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(reduceTransparency ? 0.14 : 0.08))
                    )
            }
        }
    }
}

// MARK: - Glass with an offscreen-snapshot fallback

extension EnvironmentValues {
    /// true only in ImageRenderer-based snapshot tests: glass does not rasterize offscreen,
    /// so we substitute an opaque stand-in with the same geometry.
    @Entry public var duoSnapshotMode: Bool = false
}

private struct DuoGlassModifier<S: InsettableShape>: ViewModifier {
    let glass: Glass
    let shape: S
    @Environment(\.duoSnapshotMode) private var snapshot
    func body(content: Content) -> some View {
        if snapshot {
            content
                .background(shape.fill(.background.secondary))
                .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    func duoGlass<S: InsettableShape>(_ glass: Glass = .regular, in shape: S) -> some View {
        modifier(DuoGlassModifier(glass: glass, shape: shape))
    }
}

// MARK: - Panel

/// Borderless, non-activating, click-through floating panel. Never key, never main.
public final class CompositionHUDPanel: NSPanel {
    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        // Above menus (101), Spotlight and full-screen apps; same choice as rime/Squirrel.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        worksWhenModal = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false               // glass draws its own shadow; window shadow would be rectangular
        animationBehavior = .none       // we animate in SwiftUI / alphaValue ourselves
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        isRestorable = false
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

// MARK: - Controller

@MainActor
public final class CompositionHUDController {
    public let model = CompositionHUDModel()
    private let panel = CompositionHUDPanel()
    private let hosting: NSHostingView<AnyView>
    private var hideTask: Task<Void, Never>?
    private var isShown = false
    public static let margin: CGFloat = 8

    public init() {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.rootView = AnyView(
            CompositionHUDView(model: model)
                .padding(Self.margin)
        )
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
    }

    /// Call after every keystroke that changes the composition.
    /// - Parameter caret: IMK line-height rect for character index 0 of the marked text.
    public func update(alternative: String, script: DuoScript, caret: NSRect) {
        hideTask?.cancel()
        model.alternative = alternative
        model.alternativeScript = script
        guard !alternative.isEmpty else { hide(); return }

        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let chipSize = CGSize(width: fit.width - 2 * Self.margin, height: fit.height - 2 * Self.margin)
        let screens = NSScreen.screens.map {
            HUDScreen(frame: $0.frame, visibleFrame: $0.visibleFrame, scale: $0.backingScaleFactor)
        }
        guard let placement = HUDGeometry.place(caret: caret, chipSize: chipSize,
                                                margin: Self.margin, screens: screens) else {
            hide(); return
        }
        panel.setFrame(placement.panelFrame, display: true, animate: false)
        if !isShown {
            isShown = true
            panel.alphaValue = 0
            panel.orderFrontRegardless()          // our IME process is never the active app
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0.08 : 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Call on commit / cancel. Debounced so continuous typing across word boundaries doesn't blink.
    public func hide(after delay: Duration = .milliseconds(140)) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.isShown = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isShown else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    public func noteAutoFlip() { model.autoFlipCount &+= 1 }
    public func noteManualFlip() { model.manualFlipCount &+= 1 }
}
```

참고:
* `CompositionHUDController.update(...)`는 `@Observable` 모델을 바꾼 뒤 **같은 턴 안에서** `hosting.fittingSize`를 읽음. 크기가 동기적으로 이미 최신 값임을 확인함. 예를 들어 `"dk"` → 132.5, `"dkssudgktpdy"` → 210.5이고, 런 루프 한 턴 뒤에도 값이 같음.
* 입력기 프로세스는 절대 활성 앱이 되지 않음. `orderFrontRegardless()`가 꼭 필요함. `NSApp.activate`는 절대 호출하면 안 됨. 클라이언트의 포커스를 빼앗아 입력이 깨지기 때문임.
* 다른 레이아웃 방식: 크고 투명한 고정 패널을 두고 SwiftUI로 칩 위치를 잡음. 유리가 창 뒤의 내용을 샘플링하므로 이 방식도 제대로 렌더링됨. 그래도 채택하지 않음. "Displays have separate Spaces"가 켜져 있으면, 두 디스플레이에 걸친 패널은 더 많이 걸친 디스플레이에만 나타남. 그러면 칩이 가려질 수 있음. 크기를 내용에 맞추는 방식은 이 문제를 피함.
* 선택 사항인 다듬기: IMK `mark(forStyle:at:)` 속성으로 조합 문자열 밑줄에 언어 색을 입힘. 밑줄 색을 무시하는 클라이언트가 많으므로 있으면 좋은 정도로 봄.

### 2.7 스냅샷용 유리 대체물

`ImageRenderer`는 `.glassEffect`가 붙은 뷰를 내용까지 통째로 빼먹어요(확인함: 배경만 나왔어요). 그래서 HUD는 유리를
`duoGlass(_:in:)`를 거쳐 그려요. 이 함수는 `\.duoSnapshotMode == true`일 때 불투명한 캡슐(`.background.secondary` + `.separator` 테두리 + 그림자)로
바꿔 넣어요. 덕분에 어떤 헤드리스 테스트에서든 `ImageRenderer`로 레이아웃, 타이포그래피, 말줄임, 다크 모드, 대비 증가를 픽셀 단위로
테스트할 수 있어요.

### 2.8 실제로 본 것

* `out/snapshot-{light,dark}{,-hc}.png`(대체물을 쓴 ImageRenderer): 칩 세 개, `dkssud ⇧ Space`, `안녕하세요 ⇧ Space`, `rk ⌘`. 크기가 맞고 배지 색도 맞음. 고대비에서 가는 선이 보임.
* `out/sck-panel-swiftui.png`: 그라데이션 창 위에 투명한 `CompositionHUDPanel`을 올린 **실제** 캡처. 유리가 뒤쪽 창을 굴절시키고 흐리게 함(칩 아래의 "가나다 ABC"가 뿌옇게 지워짐). 캡슐 가장자리는 선명함.
* `out/sck-panel-appkit.png`: 같은 장면에서 `NSGlassEffectView`를 `contentView`로 씀. 똑같아 보임.
* `out/sck-panel-{light,dark}.png`: 어두운 부분과 밝은 부분이 섞인 배경 위의 라이트/다크 변형. 두 경우 모두 텍스트가 잘 읽힘.

---

## 3. 호스트 앱 "Duo" (/Applications에 있음)

### 3.1 씬 구조

호스트 앱이 하는 일은 설정뿐이에요. 그래서 시스템 설정과 같은 방식으로 동작해요. **사이드바 창 하나**예요. 앱 메뉴의 "Settings…"(⌘,)도 같은 창을 열어요. 그래서 설정 창이 중복되지 않아요. 표준 About 패널은 앱 메뉴에 그대로 두고, 정보(About) 화면이 같은 내용을 보여 줘요.

```swift
import SwiftUI

@main
struct DuoApp: App {
    @AppStorage("didOnboard", store: .duo) private var didOnboard = false

    var body: some Scene {
        // The host app *is* the settings surface: one sidebar window, opened by ⌘, too.
        Window("Duo", id: "main") {
            SettingsRootView()
        }
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) { OpenSettingsCommand() }
        }

        Window("Welcome to Duo", id: "onboarding") {
            OnboardingView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(didOnboard ? .suppressed : .presented)
        .restorationBehavior(.disabled)
    }
}

struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { openWindow(id: "main") }
            .keyboardShortcut(",", modifiers: .command)
    }
}
```

* 메인 창: 기본 760×540, 최소 680×460, `windowResizability(.contentMinSize)`, 통합 툴바. 제목은 현재 화면(pane)의 이름임.
* 사이드바: `Label { Text } icon: { SettingsIcon }`을 쓰는 `List(selection:)`. 열 너비는 180 / 200 / 240(최소 / 이상적 / 최대). macOS 26에서는 사이드바가 자동으로 떠 있는 Liquid Glass 사이드바가 됨. 머티리얼을 따로 넣지 않음.
* 상세: `Form { … }.formStyle(.grouped)`를 쓰면 시스템 설정과 똑같은 모양이 나옴. 둥근 안쪽 그룹, 13 pt 본문, 섹션 머리글과 바닥글.
* 온보딩: **620×540** 고정 창. `.windowStyle(.hiddenTitleBar)`, `.windowResizability(.contentSize)`, `.defaultLaunchBehavior(didOnboard ? .suppressed : .presented)`. 실행할 때 `InputSourceStatus.current() != .selected`이면 그때도 보여 줌.

### 3.2 온보딩 (4단계)

| 단계 | 내용 | 넘어가기 |
|---|---|---|
| 1 환영 | 앱 아이콘 96 pt. SF Pro 30 pt bold로 "Welcome to Duo". 부제는 `.title3` secondary로 "Type 한국어 and English on one keyboard — no switching, ever." **히어로 모핑**: SF Pro Rounded 56 pt bold 텍스트가 1.6 s마다 `dkssud`(파랑) ↔ `안녕`(주황)으로 번갈아 바뀜. `.contentTransition(.interpolate)`과 spring(0.6, 0.2)을 씀. 동작 줄이기에서는 불투명도 크로스페이드로 바뀜. | Continue (`.glassProminent`, ⏎) |
| 2 Duo 켜기 | `SettingsIcon("keyboard", .blue)`와 제목. 1 s마다 폴링하는(또는 `kTISNotifyEnabledKeyboardInputSourcesChanged` 분산 알림으로 갱신하는) 실시간 체크리스트: ① 설치됨 ② 키보드 › 텍스트 입력에 추가됨 ③ 선택됨. 각 행의 원은 `.contentTransition(.symbolEffect(.replace))`로 `checkmark.circle.fill`(초록)로 바뀜. "Open Keyboard Settings…" 버튼은 `x-apple.systempreferences:com.apple.Keyboard-Settings.extension`을 엶. IMK 트랙이 코드로 등록하고 켤 수 있다면(`TISRegisterInputSource` / `TISEnableInputSource` / `TISSelectInputSource`) 주 버튼 "Turn On Duo"를 추가하고, 설정 링크는 대안으로 남김. | Continue, 설치되면 활성화됨. "선택됨" 뒤 0.6 s가 지나면 자동으로 넘어감. |
| 3 써 보기 | `TextEditor`(17 pt, 모서리 반지름 14 pt 카드, `.background.secondary`), 플레이스홀더는 "안녕하세요, I'm typing in two languages…". 작은 도전 과제 세 개가 실시간으로 체크됨: "Type dkssud → 안녕", "Type hello → hello", "Flip a word with the flip key"(입력기의 공유 상태로 감지하거나, 바뀐 형태가 들어간 텍스트로 감지함). 여기서 실제 HUD가 나타남. 사용자가 제품을 이해하는 순간임. | Continue |
| 4 완료 | 초록색 64 pt `checkmark.seal.fill`과 `.symbolEffect(.bounce)`. "You're all set". 팁: 입력 메뉴가 어디 있는지, 바꾸기 키, 학습은 기기 안에서만 이뤄진다는 점. | Done을 누르면 창이 닫히고 `didOnboard`가 설정됨 |

* 레이아웃: 콘텐츠 여백은 가로 48, 위 40. 아래 막대는 여백 20 pt이고, 앞쪽에 페이지 점이 있음(6 pt 점. 활성 점은 `.tint` 색 18 pt 캡슐이고 `.snappy`로 애니메이션함). 뒤쪽에는 Back(`.glass`)과 Continue(`.glassProminent`)가 있고, 둘 다 `controlSize(.large)`.
* 단계 전환: `.move(edge:)` + `.opacity`, 방향에 따라 비대칭, `.smooth(duration: 0.4)`. 동작 줄이기에서는 0.2 s ease로 `.opacity`만 씀.

### 3.3 설정 화면

**일반(General)**
* 그룹 1(상태): `LabeledContent("Duo input source") { InputSourceStatusBadge }`. Active는 초록 `checkmark.circle.fill`, Enabled는 secondary `checkmark.circle`, Not enabled는 주황 `exclamationmark.triangle.fill`, Not installed는 빨강 `xmark.circle.fill`로 보여 줌. 상태가 Active가 아니면 "Open Keyboard Settings…" 버튼이 나타남.
* **전환(Switching)** 그룹: `Picker("Flip key")`, 선택지는 Shift–Space ⇧ Space / Right Command ⌘ / Right Option ⌥ / Tab ⇥. 각 행에 `KeyCaps`를 보여 줌. 기본값과 실제 키 처리는 엔진 트랙이 맡음. 그다음에 `Toggle("Show alternative while typing")`, 그리고 `Toggle("Show flip key hint")`가 옴. 뒤의 토글은 HUD가 꺼져 있으면 비활성화됨. 바닥글: "Press the flip key to swap the word you're typing between 한국어 and English. Duo remembers the correction."
* **감지(Detection)** 그룹: `Slider(value: $bias, in: -1...1, neutralValue: 0)`. 최솟값 레이블은 "한국어", 최댓값 레이블은 "English", 눈금은 −1, 0, 1. `neutralValue`가 0이라서 채움이 가운데에서부터 자람(macOS 26). 바닥글: "If Duo often guesses the wrong language, move the slider toward the one you type most."

**학습(Learning)**
* `Toggle("Learn from corrections")`. 바닥글: "Learning happens on this Mac. Nothing you type leaves your device."
* **개인 사전(Personal Dictionary)** 섹션: 각 행에 20 pt 언어 배지, body medium으로 쓴 출력, `caption.monospaced()` secondary로 쓴 입력한 키, 뒤쪽에 tertiary 고정폭 숫자로 쓴 사용 횟수 `N×`가 나옴. 각 행에는 "Remove"(`trash`, destructive)가 든 컨텍스트 메뉴가 있음. `.searchable(text:placement: .toolbar, prompt: "Search words")`로 Tahoe 툴바 검색 필드를 추가함. 빈 상태는 `character.book.closed.ko`와 "No Learned Words" / "No Results"를 쓴 `ContentUnavailableView`임. 항목이 약 500개를 넘으면 섹션을 정렬 가능한 열(Word, Keys, Language, Uses, Last used)이 있는 `Table`로 바꿈.
* `Button("Reset Learning…", role: .destructive)`는 `confirmationDialog("Reset everything Duo has learned?")`를 엶. 메시지는 "Your personal dictionary will be erased. This can't be undone."임.

**정보(About)**: 가운데 정렬한 128 pt 앱 아이콘, 28 pt bold "Duo", `.title3` secondary로 쓴 태그라인 "One keyboard. 두 언어.", callout tertiary로 쓴 버전, `controlSize(.large)` `.glass` 버튼 "Privacy"와 "Acknowledgements"로 이뤄져요.

**환경설정 저장소**: `@AppStorage(..., store: .duo)`로 `UserDefaults(suiteName: "app.duo.shared")`를 써요. 입력기 프로세스와 공유해요(둘 다 샌드박스가 아니에요). 입력기는 같은 키를 읽고, KVO로 관찰하거나 `activateServer` 때 다시 읽을 수 있어요. 키는 `flipKey`, `showHUD`, `showKeyHint`, `languageBias`(Double −1…1), `learningEnabled`, `didOnboard`예요. suite 이름과 번들 ID는 임시값이고, 리드가 확정해요.

설정 화면, 온보딩, TIS 상태의 컴파일된 전체 소스는 부록 B에 있어요.

### 3.4 토큰

| 토큰 | 값 |
|---|---|
| 글꼴 | 모든 곳에 SF Pro(시스템). SF Pro **Rounded**는 키캡과 온보딩 히어로에만 씀. 한글은 자동으로 Apple SD Gothic Neo로 대체되므로 한국어 글꼴을 따로 지정하지 않음. |
| 글자 크기 단계(type ramp) | 온보딩 제목 30 bold / 히어로 56 rounded bold / 부제 `.title3` (15) / 본문 13 (Form 기본값) / 바닥글 시스템 / HUD 14 medium / 키캡 10–11 rounded semibold / 키 순서는 caption mono |
| 색 | 시스템 동적 색만 씀. 한국어 = `Color.orange` (systemOrange), 영어 = `Color.blue` (systemBlue). 상태는 초록/주황/빨강, 텍스트는 `.primary/.secondary/.tertiary`. 강조색은 기본값. 16진수 색 값은 아이콘에만 나옴. |
| 간격 | 4 pt 그리드. HUD는 위에서 말한 4/6/28/5/8. 창 콘텐츠 20. 온보딩 48/40/20. 카드 모서리 반지름은 14 continuous(컨테이너 도형 안에 중첩되면 `ConcentricRectangle()`). 사이드바 아이콘 타일은 22 pt, 반지름 6, 글리프는 `color.gradient` 위에 12 pt semibold 흰색. |
| 모션 | 작은 상태 변화(점, 목록 삭제)에는 `.snappy`. 단계 변화에는 `.smooth(0.4)`. 텍스트 모핑에는 spring. 모두 동작 줄이기용 변형이 있음. |

### 3.5 SF Symbols (모두 이 기기에 있는지 확인함)

`character` (A), `character.ko` (가), `character.textbox(.ko)`, `character.book.closed.ko` (학습), `textformat.ko`,
`character.cursor.ibeam.ko`, `keyboard`, `gearshape.fill` (일반), `info.circle.fill` (정보), `arrow.left.arrow.right` (바꾸기 동작),
`checkmark.circle.fill`, `circle`, `exclamationmark.triangle.fill`, `xmark.circle.fill`, `checkmark.seal.fill`, `trash`, `magnifyingglass`,
`lock.shield` (개인정보), `sparkles`, `shift`, `command`, `option`, `space`, `return`. (`hangul`은 **없어요**.)
SF Symbols 라이선스는 앱 아이콘에 심볼을 쓰는 것을 금지해요. 아래 아이콘 도형을 손으로 만든 이유 중 하나예요.

### 3.6 입력기 입력 메뉴 (IMK `menu()`, 트랙 간 참고)

항목은 순서대로 "Flip Current Word ⇧Space"(조합 중에만 활성화) — 구분선 — "Show Alternative While Typing"(체크 표시 토글) —
구분선 — "Duo Settings…"(`NSWorkspace.shared.openApplication(at:configuration:)`로 호스트 앱을 엶) — "About Duo"예요. Tahoe 메뉴와 맞추려면 SF Symbol
이미지(`arrow.left.arrow.right`, `gearshape`)를 써요. `NSMenuItem.preferredImageVisibility`는 27 전용이라 쓰지 않아요.

---

## 4. 아이콘

### 4.1 Icon Composer `.icon` 형식 (실제 배포된 번들에서 얻은 스키마, 렌더링으로 검증함)

`.icon`은 **폴더**예요.

```
AppIcon.icon/
  icon.json
  Assets/            ← SVG (preferred, 1024×1024 viewBox) or PNG (1024 px) layer art; referenced by file name
```

`icon.json` 키는 `/Applications/LINE.app/Contents/Resources/LiquidGlass_LINE.icon`과 제가 생성한 파일에서 가져왔어요. 생성한 파일은 `ictool`과 `actool` 모두 받아들였어요.

```text
root:
  fill | fill-specializations          background: "automatic" | {"solid": COLOR} | {"linear-gradient": [COLOR, COLOR]}
  groups: [GROUP]                      groups[0] is the TOP-most
  supported-platforms: {"squares": "shared" | ["macOS", "iOS", ...], "circles": ["watchOS"]}
GROUP:
  name, hidden (bool), layers: [LAYER] (layers[0] top-most)
  lighting: "individual" | "combined"
  shadow | shadow-specializations      {"kind": "neutral" | "layer-color" | "none", "opacity": 0...1}
  translucency | translucency-specializations   {"enabled": bool, "value": 0...1}
  specular | specular-specializations  bool
  blur-material | blur-material-specializations number | null
  blend-mode | blend-mode-specializations       "normal" | "multiply" | ...
  opacity, position {"scale": n, "translation-in-points": [x, y]}
LAYER:
  name, image-name (file in Assets/), hidden
  fill | fill-specializations          "automatic" | {"solid": COLOR} | {"linear-gradient": [...]}  (recolours the SVG)
  glass | glass-specializations        bool  (Liquid Glass on this layer)
  opacity | opacity-specializations, blend-mode(-specializations), position
SPECIALIZATION array element: {"appearance": "dark" | "tinted" | (absent = default/light), "value": ...}
COLOR string: "srgb:r,g,b,a" or "display-p3:r,g,b,a" (0...1 floats, 5 decimals in Apple's output)
```

### 4.2 도구 체인 (확인함)

* `ictool`은 `/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`에 있음(버전 27.2). 화면 없이(headless) 미리보기를 렌더링함:
  `ictool AppIcon.icon --export-image --output-file out.png --platform macOS --rendition Default|Dark|TintedLight|TintedDark|ClearLight|ClearDark --width 512 --height 512 --scale 1 [--design-generation 26|27]`.
  성공하면 `{}`를 출력함. 여섯 가지 렌디션을 모두 렌더링해서 직접 봄.
* `actool`은 `.icon`을 바로 컴파일함. `xcrun actool AppIcon.icon --compile OUT --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist p.plist`는 `Assets.car`(1.9 MB)와 **`AppIcon.icns`**(레거시 대체 파일이 자동 생성됨)를 만들고, plist에 `CFBundleIconFile`/`CFBundleIconName = AppIcon`을 추가함.
* **XcodeGen 2.46.0**: `AppIcon.icon`을 타깃의 `sources` 경로 아래 아무 곳에나 둠. Resources 단계에 `lastKnownFileType = wrapper.icon`으로 들어감. `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`을 설정하면 Xcode 빌드가 `actool …/AppIcon.icon --app-icon AppIcon`을 실행함. 프로브 프로젝트로 확인함: **BUILD SUCCEEDED**, `.app`에 `AppIcon.icns` + `Assets.car`가 들어 있고 Info.plist 아이콘 키가 설정됨. `.icon`을 `Assets.xcassets` 안에 넣지 **않음**. (AccentColor 등을 위한) `Assets.xcassets`는 옆에 함께 둘 수 있음.
* 혹시 필요할 때 쓸 대안: PNG 10개(16, 32, 128, 256, 512의 @1x/@2x, 즉 16…1024 px)와 `"idiom":"mac"`을 쓰는 `Contents.json`이 든 `Assets.xcassets/AppIcon.appiconset`. PNG는 `ictool --rendition Default --width N --height N --scale 1|2`로 생성함. 26.0 타깃에서는 필요 없음.

### 4.3 콘셉트와 아트워크

**"두 개의 키캡"**: **가**가 새겨진 따뜻한 주황색 둥근 사각형 키캡이 뒤쪽 왼쪽 위에 있어요. **A**가 새겨진 차가운 파란색 키캡이 오른쪽 아래에서 그 위에 겹쳐요.
배경은 거의 흰색 → 차가운 회색 그라데이션이에요(Icon Composer가 다크 버전을 자동으로 만들어요). 두 타일 레이어 모두 `glass: true`,
반사 하이라이트(specular), 레이어 색 그림자, 합친 조명(combined lighting), 약간의 반투명을 써요. 그래서 겹친 부분이 유리 위의 유리로 보여요.
글리프는 손으로 만든 획 도형이에요(둥근 끝과 이음, `CGPath.copy(strokingWithWidth:)` + `.normalized()`로 윤곽선을 만듦). 폰트 윤곽선을 쓰지 않아서 SF / Apple SD Gothic 라이선스 문제가 없어요.
확인한 렌디션은 Default, Dark(어두운 배경, 타일은 색 유지), Tinted light/dark(단색 보라 틴트, 그래도 잘 읽힘), Clear light/dark예요.
주의: 이 콘셉트는 글리프 타일 두 개를 쓰는 Apple 번역(Translate) 아이콘과 같은 계열이에요. 다만 우리는 말풍선이 아니라 키캡을 써요. 너무 비슷하다면, 키캡 하나를 대각선으로 나눠 가 / A를 넣는 변형도 있어요.

생성한 `icon.json`:

```json
{
  "fill" : {
    "linear-gradient" : [
      "display-p3:0.98039,0.98039,0.99216,1.00000",
      "display-p3:0.86667,0.87843,0.92157,1.00000"
    ]
  },
  "groups" : [
    {
      "name" : "Latin",
      "layers" : [
        { "name" : "glyph-latin", "image-name" : "glyph-latin.svg", "fill" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }, "glass" : false },
        { "name" : "tile-latin", "image-name" : "tile-latin.svg", "fill" : { "linear-gradient" : [ "display-p3:0.25098,0.61176,1.00000,1.00000", "display-p3:0.00000,0.40000,0.94118,1.00000" ] }, "glass" : true }
      ],
      "lighting" : "combined",
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.35 },
      "specular" : true
    },
    {
      "name" : "Hangul",
      "layers" : [
        { "name" : "glyph-hangul", "image-name" : "glyph-hangul.svg", "fill" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }, "glass" : false },
        { "name" : "tile-hangul", "image-name" : "tile-hangul.svg", "fill" : { "linear-gradient" : [ "display-p3:1.00000,0.70196,0.25098,1.00000", "display-p3:1.00000,0.45098,0.18824,1.00000" ] }, "glass" : true }
      ],
      "lighting" : "combined",
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.2 },
      "specular" : true
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}
```

생성기(`AppIcon.icon/`과 `DuoMenuIcon.tiff`를 만들어요. `swift GenerateIcons.swift <outdir>`로 실행하거나 `swiftc`로 컴파일해요):

```swift
// Generates Duo's artwork from code — no hand-made binaries, no font outlines (license-clean):
//   1. AppIcon.icon/            Icon Composer bundle (icon.json + Assets/*.svg)
//   2. DuoMenuIcon.tiff         16x16@1x + 32x32@2x template TIFF for the input-source menu
// Usage: swift GenerateIcons.swift <outdir>
import AppKit
import CoreGraphics

// MARK: Geometry (SVG space: 1024x1024, y grows DOWN)

/// "가" as rounded strokes: ㄱ (bar + sweeping descender) and ㅏ (stem + tick).
func hangulGa(center c: CGPoint, scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    // ㄱ
    p.move(to: pt(-112, -78))
    p.addLine(to: pt(-14, -78))
    p.addQuadCurve(to: pt(-96, 100), control: pt(-14, 40))
    // ㅏ
    p.move(to: pt(48, -118))
    p.addLine(to: pt(48, 118))
    p.move(to: pt(48, -2))
    p.addLine(to: pt(112, -2))
    return p
}

/// "A" as rounded strokes.
func latinA(center c: CGPoint, scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    p.move(to: pt(-92, 112))
    p.addLine(to: pt(0, -112))
    p.addLine(to: pt(92, 112))
    p.move(to: pt(-56, 40))
    p.addLine(to: pt(56, 40))
    return p
}

func outline(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        .normalized()   // merge overlaps (macOS 13+) so nonzero fill never punches holes
}

func roundedTile(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: SVG emission

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { el in
        let e = el.pointee, p = e.points
        switch e.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(_ path: CGPath) -> String {
    """
    <svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
    <path d="\(svgPathData(path))" fill="white"/>
    </svg>

    """
}

// MARK: Icon Composer document

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconDir = out.appendingPathComponent("AppIcon.icon")
let assets = iconDir.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// Two keycaps, overlapping on the diagonal: 가 (back, warm) and A (front, cool).
let tileSize: CGFloat = 420, radius: CGFloat = 112
let backRect = CGRect(x: 158, y: 166, width: tileSize, height: tileSize)
let frontRect = CGRect(x: 446, y: 438, width: tileSize, height: tileSize)
let files: [String: CGPath] = [
    "tile-hangul.svg": roundedTile(backRect, radius: radius),
    "glyph-hangul.svg": outline(hangulGa(center: CGPoint(x: backRect.midX - 6, y: backRect.midY), scale: 1.0), width: 40),
    "tile-latin.svg": roundedTile(frontRect, radius: radius),
    "glyph-latin.svg": outline(latinA(center: CGPoint(x: frontRect.midX, y: frontRect.midY + 4), scale: 1.0), width: 42),
]
for (name, path) in files {
    try svg(path).write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// icon.json — keys verified against a shipping .icon bundle and rendered with `ictool`.
// groups[0] is the TOP-most group; layers[0] is the top-most layer inside a group.
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "display-p3:0.98039,0.98039,0.99216,1.00000",
      "display-p3:0.86667,0.87843,0.92157,1.00000"
    ]
  },
  "groups" : [
    {
      "name" : "Latin",
      "layers" : [
        { "name" : "glyph-latin", "image-name" : "glyph-latin.svg", "fill" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }, "glass" : false },
        { "name" : "tile-latin", "image-name" : "tile-latin.svg", "fill" : { "linear-gradient" : [ "display-p3:0.25098,0.61176,1.00000,1.00000", "display-p3:0.00000,0.40000,0.94118,1.00000" ] }, "glass" : true }
      ],
      "lighting" : "combined",
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.35 },
      "specular" : true
    },
    {
      "name" : "Hangul",
      "layers" : [
        { "name" : "glyph-hangul", "image-name" : "glyph-hangul.svg", "fill" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" }, "glass" : false },
        { "name" : "tile-hangul", "image-name" : "tile-hangul.svg", "fill" : { "linear-gradient" : [ "display-p3:1.00000,0.70196,0.25098,1.00000", "display-p3:1.00000,0.45098,0.18824,1.00000" ] }, "glass" : true }
      ],
      "lighting" : "combined",
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.2 },
      "specular" : true
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}

"""
try iconJSON.write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("wrote", iconDir.path)

// MARK: Menu-bar input-source icon (template: black + alpha only)

/// Draws at `px` pixels for a 16pt icon. Filled rounded tile with 가 and A knocked out (like Apple's 한 icon).
func menuIconRep(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 16, height: 16)               // 16pt regardless of pixel count => @1x / @2x
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = ctx.cgContext
    // NSGraphicsContext(bitmapImageRep:) already maps rep.size (16pt) onto the pixel grid,
    // so we draw in points for every representation.
    // flip to y-down so we can reuse the SVG-style glyph builders
    cg.translateBy(x: 0, y: 16); cg.scaleBy(x: 1, y: -1)
    cg.setFillColor(NSColor.black.cgColor)
    cg.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 16, height: 16), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
    cg.fillPath()
    cg.setBlendMode(.clear)                                 // knock out the glyphs
    let ga = outline(hangulGa(center: CGPoint(x: 4.7, y: 8.0), scale: 0.0265), width: 1.5)
    let a = outline(latinA(center: CGPoint(x: 11.85, y: 8.2), scale: 0.0235), width: 1.5)
    cg.addPath(ga); cg.addPath(a); cg.fillPath()
    return rep
}
let reps = [menuIconRep(px: 16), menuIconRep(px: 32)]
let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0)!
try tiff.write(to: out.appendingPathComponent("DuoMenuIcon.tiff"))
// Large preview for eyeballing
for px in [16, 32, 256] {
    // flatten onto white so the preview is viewable
    let big = menuIconRep(px: px)
    let flat = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { r in
        NSColor.white.setFill(); r.fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        big.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        return true
    }
    let tiffData = flat.tiffRepresentation!
    try NSBitmapImageRep(data: tiffData)!.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("DuoMenuIcon-preview-\(px).png"))
}
print("wrote DuoMenuIcon.tiff")
```

### 4.4 입력 소스 (메뉴 막대) 아이콘

Apple이 배포하는 형식이에요(`/System/Library/Input Methods/KoreanIM.app/Contents/PlugIns/KIM_Extension.appex`와 `TamilIM.app`에서 읽음).

* 형식은 **다중 표현(multi-representation) TIFF**임: 16×16 px @72 dpi + 32×32 px @144 dpi(Apple 파일에는 `2SetKorean.png` / `2SetKorean@2x.png` 같은 설명이 붙어 있음. 즉 `tiffutil -cathidpicheck`로 만들었음). 디자인은 **16 pt 꽉 찬 둥근 사각형(반지름 ≈ 3.5 pt)을 검정으로 채우고 글리프를 투명하게 뚫은 형태**임. 획은 1–1.5 pt, 글리프 높이는 약 10 pt.
* Info.plist 키:
  * 최상위: `TISIconIsTemplate = YES`(시스템이 라이트, 다크, 선택 상태에 맞게 색을 입힘), `tsInputMethodIconFileKey = "DuoMenuIcon.tiff"`, `TISIntendedLanguage`, `TISInputSourceID`.
  * 모드별(IMK 트랙이 `ComponentInputModeDict` → `tsInputModeListKey`를 쓴다면): `tsInputModeMenuIconFileKey`, `tsInputModePaletteIconFileKey`, `TISIconLabels = { Primary = "한"; }`. Apple이 이 짧은 텍스트 레이블을 설정함. 문서화되지 않았고, Caps Lock / 입력 전환 표시기가 쓸 수도 있음. Duo에는 `Primary = "가A"`를 제안함(확인 필요).
  * Apple의 한국어 plist에는 `.png`라고 적혀 있지만 실제 파일은 `.tiff`임(번들 이미지 조회가 기본 이름으로 찾음). 안전하게 실제 파일 이름을 적음.
* 우리 아이콘(생성함, `alpha` 덤프 확인, 32 px 미리보기 직접 봄): **가**와 **A**를 나란히 뚫은 타일. 16 px에서는 읽히지만 빽빽함. 32 px(Retina, 거의 모든 Tahoe Mac이 보여 주는 크기)에서는 깔끔함.

---

## 5. TCC 권한 없이(그렇게 가정함) 시각 결과 확인하기

| 기법 | 이 기기에서의 결과 | 용도 |
|---|---|---|
| `ImageRenderer(content:)` → `cgImage` | 헤드리스로 동작함. **`.glassEffect`가 붙은 뷰는 내용까지 통째로 빠짐.** 플랫폼 기반 컨트롤(Form/List 행)은 렌더링되지 않음. | `duoSnapshotMode`(유리 대체물)를 쓴 순수 SwiftUI 레이아웃 테스트. Swift Testing의 픽셀·크기 단언. |
| `NSView.bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` | SwiftUI 텍스트와 컨트롤은 렌더링됨. SwiftUI 유리는 **투명**하게 나오고, 색이 있는 내용은 바래 보임. `NSGlassEffectView`는 **내용을 가리는 불투명한 흰 판**으로 렌더링됨. Form과 List는 **창을 순서에 넣지 않으면 비어 있음**. 그래서 창을 `(-30000,-30000)`에 두고 `orderFrontRegardless()`한 뒤 런 루프를 약 0.5 s 돌림. 프로세스가 활성 상태가 아니라서 강조색과 토글은 *비활성*(회색) 스타일로 렌더링됨. 테두리 없는 창은 `backgroundColor`를 설정해야 함. 아니면 투명 PNG에서 다크 모드 텍스트가 사라짐. | 설정/온보딩 레이아웃, 다크 모드, 텍스트 잘림. |
| `CALayer.render(in:)` | cacheDisplay와 같음(유리 = 흰 판). | — |
| `CGWindowListCreateImage` | **컴파일 오류**: *"'CGWindowListCreateImage' is unavailable in macOS: Please use ScreenCaptureKit instead."* (`SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0)`) | — |
| **ScreenCaptureKit, 우리 창만** | 이 세션에서 `CGPreflightScreenCaptureAccess()`가 **true**를 돌려줬고, `SCScreenshotManager.captureImage`가 **실제 Liquid Glass**를 캡처함. 단일 창(`SCContentFilter(desktopIndependentWindow:)`)에서도, 우리 창 여러 개를 합친 경우(`SCContentFilter(display:including: [ourWindows])` + `sourceRect`)에도 동작함. 창은 `orderBack(nil)`로 (0,0)에 두었음. 즉 다른 모든 창 뒤에 있어서 거슬리는 것이 화면에 보이지 않음. 화면 밖에 둔 창은 SCStream 오류 **-3811**로 실패함. | 진짜 유리를 볼 수 있는 **유일한** 방법. `CGPreflightScreenCaptureAccess()`로 확인한 뒤에만 쓰고, 안 되면 1–2행 방법으로 돌아감. 권한은 책임 프로세스(터미널 / 에이전트 호스트)에 속함. 그래서 `xcodebuild`로 테스트를 돌리면 달라질 수 있음. |

캡처 방법(확인함):

```swift
import AppKit
import SwiftUI
import ScreenCaptureKit

// Does glass inside a CLEAR borderless NSPanel sample what is behind the panel (another window)?
// Both windows are ours, ordered behind every other window; capture composites only these two.

struct BackdropView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.15), .indigo, Color(white: 0.9), .black, .teal, .purple],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("가나다 ABC 가나다 ABC").font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
        }
        .frame(width: 320, height: 120)
    }
}

@MainActor
func run(out: URL, style: String) async {
    let frame = NSRect(x: 0, y: 0, width: 320, height: 120)
    let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    backdrop.contentView = NSHostingView(rootView: BackdropView())
    backdrop.orderBack(nil)

    let panel = CompositionHUDPanel()
    panel.level = .normal                       // test only: keep it behind the user's windows
    let model = CompositionHUDModel(); model.alternative = "dkssud"
    if style == "appkit" {
        // AppKit: NSGlassEffectView as the panel's content view, SwiftUI inside (no SwiftUI glass)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        let host = NSHostingView(rootView: Text("dkssud  ⇧ Space").font(.system(size: 14, weight: .medium)).padding(.horizontal, 12).frame(height: 28))
        glass.contentView = host
        panel.contentView = glass
        panel.setFrame(NSRect(x: 80, y: 46, width: 160, height: 28), display: true)
    } else {
        let host = NSHostingView(rootView: CompositionHUDView(model: model).padding(8))
        panel.contentView = host
        let size = host.fittingSize
        panel.setFrame(NSRect(x: 60, y: 60 - size.height / 2, width: size.width, height: size.height), display: true)
    }
    panel.order(.above, relativeTo: backdrop.windowNumber)
    try? await Task.sleep(for: .milliseconds(600))
    defer { panel.orderOut(nil); backdrop.orderOut(nil) }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mine = content.windows.filter { [backdrop.windowNumber, panel.windowNumber].contains(Int($0.windowID)) }
        guard mine.count == 2, let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: 1, y: 1)) }) ?? content.displays.first else {
            print("windows found:", mine.count); return
        }
        let filter = SCContentFilter(display: display, including: mine)
        let cfg = SCStreamConfiguration()
        let screenH = NSScreen.screens[0].frame.height
        cfg.sourceRect = CGRect(x: 0, y: screenH - 120, width: 320, height: 120)   // top-left-origin display points
        cfg.width = 640; cfg.height = 240
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: out)
        print("wrote", out.path)
    } catch { print("SCK error:", error) }
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let style = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "swiftui"
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
Task { @MainActor in await run(out: out, style: style); exit(0) }
NSApp.run()
```

화면 밖 `cacheDisplay` 방법(Form에서 확인함):

```swift
import AppKit
import SwiftUI

@MainActor
func snapshot<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL, settle: Double = 0.6) {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: appearance)
    win.contentView = host
    // Park the window far outside every display: it is "visible" to AppKit/SwiftUI
    // (so lists/forms realize their rows) but no pixel reaches any screen.
    win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    win.orderFrontRegardless()
    defer { win.orderOut(nil) }
    // Let SwiftUI/AppKit finish layout & async work without ordering the window on screen.
    RunLoop.main.run(until: Date().addingTimeInterval(settle))
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", url.lastPathComponent)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    for a in [NSAppearance.Name.aqua, .darkAqua] {
        let tag = a == .aqua ? "light" : "dark"
        snapshot(SettingsRootView(), size: NSSize(width: 760, height: 540), appearance: a, to: out.appendingPathComponent("settings-general-\(tag).png"))
        snapshot(GeneralPane(), size: NSSize(width: 560, height: 540), appearance: a, to: out.appendingPathComponent("pane-general-\(tag).png"))
        snapshot(LearningPane(), size: NSSize(width: 560, height: 540), appearance: a, to: out.appendingPathComponent("pane-learning-\(tag).png"))
        snapshot(AboutPane(), size: NSSize(width: 560, height: 420), appearance: a, to: out.appendingPathComponent("pane-about-\(tag).png"))
        snapshot(OnboardingView(), size: NSSize(width: 620, height: 540), appearance: a, to: out.appendingPathComponent("onboarding-welcome-\(tag).png"))
        snapshot(EnableStep().padding(48), size: NSSize(width: 620, height: 460), appearance: a, to: out.appendingPathComponent("onboarding-enable-\(tag).png"))
        snapshot(TryItStep().padding(48), size: NSSize(width: 620, height: 460), appearance: a, to: out.appendingPathComponent("onboarding-try-\(tag).png"))
    }
}
```

---

## 6. 위험 요소 / 미결 항목

1. **활성화되지 않는 프로세스에서의 유리.** 캡처는 `.prohibited` 프로세스에서 나왔음. 입력기와 같은 상황(절대 활성화되지 않음)이고, 유리는 제대로 보였음. 그래도 실제 하드웨어에서 "비활성" 채도 저하가 생기는지 지켜봐야 함.
2. **창 레벨** `CGShieldingWindowLevel()`은 HUD를 화면 보호기와 잠금 화면 가림막을 포함한 모든 것 위에 둠. `NSWorkspace.screensDidSleepNotification` / 세션 resign 때 HUD를 숨김. 이것이 문제라면 `.popUpMenu + 1`이 보수적인 대안임. 다만 Spotlight 아래로 갈 수 있음.
3. 일부 클라이언트(Terminal, 일부 Electron·Java 앱)는 오래된 캐럿 사각형이나 `.zero`를 돌려줌. 기하 계산은 엉터리 값이 오면 숨김. IMK 트랙은 두 번째 출처로 `firstRect(forCharacterRange:actualRange:)`도 시도해야 함.
4. 4.4절에서 말했듯이 `TISIconLabels`의 의미는 문서화되지 않았음.
5. 아이콘이 분위기상 Apple 번역(Translate)과 닮았음(4.3절 참고).
6. 여기서 쓴 번들 ID와 suite 이름(`app.duo.inputmethod`, `app.duo.shared`)은 임시값임. 리드의 project.yml과 맞춰야 함.

---

## 부록 A — 유리 API 목록 (26.0에서 컴파일됨, -warnings-as-errors)

```swift
// Compile-only inventory of every macOS 26 Liquid Glass API Duo might use.
// Built with: swiftc -swift-version 6 -target arm64-apple-macos26.0 -warnings-as-errors -parse-as-library
import SwiftUI
import AppKit
import Observation

struct GlassInventory: View {
    @Namespace private var ns
    @State private var expanded = false
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 12) {                       // merges nearby glass shapes
                    HStack(spacing: 8) {
                        Text("가").padding(10)
                            .glassEffect()                                 // .regular in DefaultGlassEffectShape (capsule)
                            .glassEffectID("ko", in: ns)                   // morph identity
                        if expanded {
                            Text("A").padding(10)
                                .glassEffect(.regular.tint(.blue).interactive(), in: .circle)
                                .glassEffectID("en", in: ns)
                                .glassEffectTransition(.matchedGeometry)  // .materialize / .identity
                        }
                        Text("Clear").padding(10)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text("Off").padding(10).glassEffect(.identity)    // conditionally disable glass
                        Text("U1").padding(6).glassEffect().glassEffectUnion(id: "u", namespace: ns)
                        Text("U2").padding(6).glassEffect().glassEffectUnion(id: "u", namespace: ns)
                    }
                }
                Button("Flip") { withAnimation(.bouncy) { expanded.toggle() } }
                    .buttonStyle(.glass)
                Button("Continue") {}
                    .buttonStyle(.glassProminent)
                if #available(macOS 26.1, *) {
                    Button("Clear glass button") {}.buttonStyle(.glass(.clear))   // GlassButtonStyle.init(_:) is 26.1+
                }
                Image(systemName: "keyboard").resizable().scaledToFit().frame(height: 120)
                    .backgroundExtensionEffect()                          // mirrors/blur-extends under sidebar/toolbar
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 40)
                    .clipShape(ConcentricRectangle())                     // corners concentric with container
            }
            .scrollEdgeEffectStyle(.soft, for: .top)                      // .automatic / .hard / .soft
            .scrollEdgeEffectHidden(false, for: .bottom)
            .toolbar {
                ToolbarItem { Button("A", systemImage: "character") {} }
                ToolbarSpacer(.fixed)                                     // .flexible (default) / .fixed
                ToolbarItem { Button("가", systemImage: "character.ko") {} }
            }
            .searchable(text: $query)
        }
    }
}

@MainActor
func appKitInventory() -> NSView {
    let glass = NSGlassEffectView()
    glass.style = .regular                // .regular / .clear
    glass.cornerRadius = 14
    glass.tintColor = .systemBlue.withAlphaComponent(0.2)
    glass.contentView = NSTextField(labelWithString: "dkssud")
    if #available(macOS 27.0, *) { glass.effectIsInteractive = false }   // macOS 27 only

    let container = NSGlassEffectContainerView()
    container.spacing = 8
    container.contentView = glass

    let ext = NSBackgroundExtensionView()
    ext.contentView = NSImageView()
    ext.automaticallyPlacesContentView = true

    let button = NSButton(title: "Continue", target: nil, action: nil)
    button.bezelStyle = .glass            // NSBezelStyleGlass (26.0)
    button.tintProminence = .primary      // NSTintProminence (26.0)
    button.borderShape = .capsule         // NSControl.BorderShape (26.0)
    button.controlSize = .extraLarge      // NSControlSizeExtraLarge (26.0)

    if #available(macOS 26.1, *) {
        let acc = NSTitlebarAccessoryViewController()
        acc.preferredScrollEdgeEffectStyle = .soft   // NSScrollEdgeEffectStyle is 26.1+
    }
    return container
}

@Observable final class ObsModel: @unchecked Sendable { var word = "" }

@MainActor
func observeInventory(_ m: ObsModel) async {
    // Observation's async sequence (anyAppleOS 26): yields whenever `word` changes.
    for await w in Observations({ m.word }) { print(w); break }
}
```

## 부록 B — 호스트 앱 UI (설정 화면, 온보딩, TIS 상태) — 컴파일됨, cacheDisplay로 렌더링함

```swift
import SwiftUI
import AppKit
import Carbon

// MARK: - Shared preferences (host app <-> IME). Non-sandboxed: a named suite is shared by both processes.

extension UserDefaults {
    nonisolated(unsafe) static let duo = UserDefaults(suiteName: "app.duo.shared")!
}

enum FlipKey: String, CaseIterable, Identifiable, Sendable {
    case shiftSpace, rightCommand, rightOption, tab
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .shiftSpace: "Shift–Space"
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        case .tab: "Tab"
        }
    }
    var caps: [String] {
        switch self {
        case .shiftSpace: ["⇧", "Space"]
        case .rightCommand: ["⌘"]
        case .rightOption: ["⌥"]
        case .tab: ["⇥"]
        }
    }
}

// MARK: - Design tokens

enum DuoTokens {
    static let hangul = Color.orange      // warm = 한국어 (system color: adapts to dark + Increase Contrast)
    static let latin = Color.blue         // cool = English
    static let sidebarIcon: CGFloat = 22
    static let sidebarIconRadius: CGFloat = 6
    static let paneMaxWidth: CGFloat = 560
}

/// System Settings–style coloured squircle with a white glyph.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: DuoTokens.sidebarIcon, height: DuoTokens.sidebarIcon)
            .background(RoundedRectangle(cornerRadius: DuoTokens.sidebarIconRadius, style: .continuous)
                .fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Key caps like "⇧ Space" rendered as small rounded keys.
struct KeyCaps: View {
    let caps: [String]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(caps, id: \.self) { cap in
                Text(cap)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Settings window (System Settings idiom: sidebar + grouped Form)

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general, learning, about
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self { case .general: "General"; case .learning: "Learning"; case .about: "About" }
    }
    var symbol: String {
        switch self { case .general: "gearshape.fill"; case .learning: "character.book.closed.ko"; case .about: "info.circle.fill" }
    }
    var color: Color {
        switch self { case .general: .gray; case .learning: .orange; case .about: .blue }
    }
}

struct SettingsRootView: View {
    @State private var selection: SettingsPane? = .general
    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label { Text(pane.title) } icon: { SettingsIcon(symbol: pane.symbol, color: pane.color) }
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralPane()
                case .learning: LearningPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(Text((selection ?? .general).title))
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 680, minHeight: 460)
    }
}

struct GeneralPane: View {
    @AppStorage("flipKey", store: .duo) private var flipKey: FlipKey = .shiftSpace
    @AppStorage("showHUD", store: .duo) private var showHUD = true
    @AppStorage("showKeyHint", store: .duo) private var showKeyHint = true
    @AppStorage("languageBias", store: .duo) private var bias = 0.0   // -1 = 한국어 … +1 = English
    @State private var status = InputSourceStatus.current()

    var body: some View {
        Form {
            Section {
                LabeledContent("Duo input source") {
                    InputSourceStatusBadge(status: status)
                }
                if status != .selected {
                    Button("Open Keyboard Settings…") { InputSourceStatus.openKeyboardSettings() }
                }
            }

            Section {
                Picker("Flip key", selection: $flipKey) {
                    ForEach(FlipKey.allCases) { key in
                        HStack { Text(key.title); Spacer(); KeyCaps(caps: key.caps) }.tag(key)
                    }
                }
                Toggle("Show alternative while typing", isOn: $showHUD)
                Toggle("Show flip key hint", isOn: $showKeyHint)
                    .disabled(!showHUD)
            } header: {
                Text("Switching")
            } footer: {
                Text("Press the flip key to swap the word you're typing between 한국어 and English. Duo remembers the correction.")
            }

            Section {
                Slider(value: $bias, in: -1...1, neutralValue: 0) {
                    Text("Language preference")
                } minimumValueLabel: {
                    Text("한국어")
                } maximumValueLabel: {
                    Text("English")
                } ticks: {
                    SliderTick(-1)
                    SliderTick(0)
                    SliderTick(1)
                }
            } header: {
                Text("Detection")
            } footer: {
                Text("If Duo often guesses the wrong language, move the slider toward the one you type most.")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                status = InputSourceStatus.current()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

struct LearnedWord: Identifiable, Hashable, Sendable {
    let id = UUID()
    var keys: String        // physical keys typed, e.g. "dkssud"
    var output: String      // what Duo now produces, e.g. "안녕"
    var script: Character   // "가" or "A"
    var uses: Int
}

struct LearningPane: View {
    @AppStorage("learningEnabled", store: .duo) private var learningEnabled = true
    @State private var words: [LearnedWord] = [
        .init(keys: "rust", output: "rust", script: "A", uses: 12),
        .init(keys: "gksrmf", output: "한글", script: "가", uses: 7),
        .init(keys: "tmdnlvmxm", output: "스위프트", script: "가", uses: 3),
    ]
    @State private var query = ""
    @State private var confirmReset = false

    private var filtered: [LearnedWord] {
        query.isEmpty ? words : words.filter {
            $0.keys.localizedCaseInsensitiveContains(query) || $0.output.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Learn from corrections", isOn: $learningEnabled)
            } footer: {
                Text("Learning happens on this Mac. Nothing you type leaves your device.")
            }

            Section("Personal Dictionary") {
                if filtered.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "No Learned Words" : "No Results", systemImage: "character.book.closed.ko")
                    } description: {
                        Text(query.isEmpty ? "Words you flip with the flip key appear here." : "Try a different search.")
                    }
                } else {
                    ForEach(filtered) { word in
                        LearnedWordRow(word: word)
                            .contextMenu {
                                Button("Remove", systemImage: "trash", role: .destructive) { remove(word) }
                            }
                    }
                }
            }

            Section {
                Button("Reset Learning…", role: .destructive) { confirmReset = true }
                    .disabled(words.isEmpty)
            }
        }
        .formStyle(.grouped)
        .searchable(text: $query, placement: .toolbar, prompt: "Search words")
        .confirmationDialog("Reset everything Duo has learned?", isPresented: $confirmReset) {
            Button("Reset Learning", role: .destructive) { withAnimation { words.removeAll() } }
        } message: {
            Text("Your personal dictionary will be erased. This can't be undone.")
        }
    }

    private func remove(_ word: LearnedWord) {
        withAnimation(.snappy) { words.removeAll { $0.id == word.id } }
    }
}

struct LearnedWordRow: View {
    let word: LearnedWord
    var body: some View {
        HStack(spacing: 10) {
            Text(String(word.script))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(word.script == "A" ? DuoTokens.latin : DuoTokens.hangul))
            VStack(alignment: .leading, spacing: 1) {
                Text(word.output).font(.body.weight(.medium))
                Text(word.keys).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(word.uses)×").font(.callout).monospacedDigit().foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)!)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("Duo").font(.system(size: 28, weight: .bold))
                Text("One keyboard. 두 언어.").font(.title3).foregroundStyle(.secondary)
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button("Privacy") {}.buttonStyle(.glass)
                Button("Acknowledgements") {}.buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Input source status (TIS)

enum InputSourceStatus: Equatable {
    case notInstalled, disabled, enabled, selected
    static let bundleID = "app.duo.inputmethod"

    static func current() -> InputSourceStatus {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        let installed = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
        guard !installed.isEmpty else { return .notInstalled }
        let enabled = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        guard !enabled.isEmpty else { return .disabled }
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        if let raw = TISGetInputSourceProperty(current, kTISPropertyBundleID) {
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            if id == bundleID { return .selected }
        }
        return .enabled
    }

    @MainActor static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

struct InputSourceStatusBadge: View {
    let status: InputSourceStatus
    var body: some View {
        switch status {
        case .selected: Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .enabled: Label("Enabled", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .disabled: Label("Not enabled", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .notInstalled: Label("Not installed", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Onboarding

enum OnboardingStep: Int, CaseIterable { case welcome, enable, tryIt, done }

struct OnboardingView: View {
    @State private var step: OnboardingStep = .welcome
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case .welcome: WelcomeStep()
                case .enable: EnableStep()
                case .tryIt: TryItStep()
                case .done: DoneStep()
                }
            }
            .id(step)
            .transition(stepTransition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 40)

            HStack(spacing: 12) {
                PageDots(count: OnboardingStep.allCases.count, index: step.rawValue)
                Spacer()
                if step != .welcome && step != .done {
                    Button("Back") { go(-1) }
                        .buttonStyle(.glass)
                }
                Button(step == .done ? "Done" : "Continue") {
                    if step == .done { dismissWindow(id: "onboarding") } else { go(+1) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 620, height: 540)
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    private func go(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)) { step = next }
    }
}

struct PageDots: View {
    let count: Int, index: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: i == index ? 18 : 6, height: 6)
            }
        }
        .animation(.snappy, value: index)
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

/// Hero: the keys "dkssud" morph into "안녕" and back — shows the core idea in 2 seconds.
struct MorphingHero: View {
    @State private var showHangul = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(showHangul ? "안녕" : "dkssud")
            .font(.system(size: 56, weight: .bold, design: .rounded))
            .foregroundStyle(showHangul ? DuoTokens.hangul : DuoTokens.latin)
            .contentTransition(reduceMotion ? .opacity : .interpolate)
            .frame(height: 72)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.6))
                    withAnimation(.spring(duration: 0.6, bounce: 0.2)) { showHangul.toggle() }
                }
            }
            .accessibilityLabel("dkssud becomes 안녕")
    }
}

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)!)
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Welcome to Duo").font(.system(size: 30, weight: .bold))
            Text("Type 한국어 and English on one keyboard —\nno switching, ever.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            MorphingHero().padding(.top, 8)
        }
    }
}

struct EnableStep: View {
    @State private var status = InputSourceStatus.current()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label { Text("Turn on Duo").font(.system(size: 26, weight: .bold)) } icon: {
                SettingsIcon(symbol: "keyboard", color: .blue).scaleEffect(1.4).padding(.trailing, 6)
            }
            Text("Add Duo as an input source, then select it from the menu bar.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                ChecklistRow(done: status != .notInstalled, text: "Duo is installed")
                ChecklistRow(done: status == .enabled || status == .selected, text: "Added in Keyboard › Text Input")
                ChecklistRow(done: status == .selected, text: "Selected in the menu bar")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
            Button("Open Keyboard Settings…") { InputSourceStatus.openKeyboardSettings() }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                let s = InputSourceStatus.current()
                if s != status { withAnimation(.snappy) { status = s } }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct ChecklistRow: View {
    let done: Bool, text: LocalizedStringKey
    var body: some View {
        Label {
            Text(text).foregroundStyle(done ? .primary : .secondary)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.body)
    }
}

struct TryItStep: View {
    @State private var text = ""
    private var challenges: [(LocalizedStringKey, Bool)] {
        [("Type  dkssud  → 안녕", text.contains("안녕")),
         ("Type  hello  → hello", text.localizedCaseInsensitiveContains("hello")),
         ("Flip a word with the flip key", text.contains("ㅗ디ㅣㅐ") || text.contains("dkssud"))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it").font(.system(size: 26, weight: .bold))
            TextEditor(text: $text)
                .font(.system(size: 17))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.secondary))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("안녕하세요, I'm typing in two languages…")
                            .font(.system(size: 17)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 17).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(challenges.enumerated()), id: \.offset) { _, c in
                    ChecklistRow(done: c.1, text: c.0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DoneStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("You're all set").font(.system(size: 30, weight: .bold))
            Text("Duo lives in the menu bar's input menu. Open Duo any time to change the flip key or review what it has learned.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}
```

## 부록 C — 프로브 산출물 (스크래치패드, 지워질 수 있음)

모두 `/private/tmp/claude-501/-Users-user-orca-zlqhem/b8fa910a-9760-4366-944c-1b8329866082/scratchpad/ui-probe/` 아래에 있어요:
`out/sck-panel-{swiftui,appkit,light,dark}.png`(실제 유리 캡처), `out/sck-onscreen.png`, `out/snapshot-*.png`,
`out/imagerenderer-*.png`(유리 빠짐), `out/cachedisplay-*.png`, `out/settings-general-*.png`, `out/pane-*.png`, `out/onboarding-*.png`,
`icon/out/AppIcon.icon/`, `icon/out/icon-{Default,Dark,TintedLight,TintedDark,ClearLight,ClearDark}.png`, `icon/out/DuoMenuIcon.tiff`,
`xg/`(XcodeGen .icon 프로브 프로젝트), `pkg/`(Swift Testing 패키지).
