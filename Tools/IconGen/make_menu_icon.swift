// Renders the input-source icon as a template TIFF: a 22×16 pt rounded tile, black, with "한A"
// knocked out to transparent; one 22×16 px rep at 72 dpi and one 44×32 px rep at 144 dpi, combined
// with `tiffutil -cathidpicheck` like KoreanIM's 2SetKorean.tiff.
//
// A template (Info.plist: TISIconIsTemplate = true), like Apple's: menus and the menu bar tint it, so
// it is a dark tile in light mode and a light tile in dark mode. The size and type match the label
// badges macOS 26 draws for Apple's sources in the input menu (22×16 pt, ~4 pt corners, semibold
// ~12 pt glyphs; measured from the menu on macOS 26.6.2).
//
// Usage: swift Tools/IconGen/make_menu_icon.swift <out.tiff> [--preview <dir>]
//   --preview writes 16x-enlarged PNGs of both reps on light and dark backdrops for inspection.
import AppKit
import CoreText

let arguments = Array(CommandLine.arguments.dropFirst())
guard let outPath = arguments.first, !outPath.hasPrefix("--") else {
    FileHandle.standardError.write(Data("usage: make_menu_icon.swift <out.tiff> [--preview <dir>]\n".utf8))
    exit(2)
}
let previewDir = arguments.firstIndex(of: "--preview").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }

/// Icon geometry in points.
enum Metrics {
    static let width: CGFloat = 22
    static let height: CGFloat = 16
    static let cornerRadius: CGFloat = 4
    /// Widest ink run of "한A": the tile minus ~1.5 pt per side.
    static let maximumInkWidth: CGFloat = 19
    /// Apple's badge glyphs (A, 한) are ~12 pt.
    static let maximumFontSize: CGFloat = 12
}

func glyphLine(size: CGFloat) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: .semibold)
    let text = NSAttributedString(string: "한A", attributes: [.font: font, .foregroundColor: NSColor.black])
    return CTLineCreateWithAttributedString(text)
}

/// The largest glyph run whose ink fits ``Metrics/maximumInkWidth`` (in 0.1 pt steps).
func fittedGlyphLine(in cg: CGContext) -> CTLine {
    var size = Metrics.maximumFontSize
    while size > 6 {
        let line = glyphLine(size: size)
        if CTLineGetImageBounds(line, cg).width <= Metrics.maximumInkWidth { return line }
        size -= 0.1
    }
    return glyphLine(size: 6)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let size = CGSize(width: Metrics.width, height: Metrics.height)
    guard let cg = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create bitmap")
    }
    // Draw in points; the context maps them onto `scale` device pixels each.
    cg.scaleBy(x: scale, y: scale)
    cg.clear(CGRect(origin: .zero, size: size))

    // Tile.
    let tile = CGPath(roundedRect: CGRect(origin: .zero, size: size),
                      cornerWidth: Metrics.cornerRadius, cornerHeight: Metrics.cornerRadius, transform: nil)
    cg.addPath(tile)
    cg.setFillColor(CGColor(gray: 0, alpha: 1))
    cg.fillPath()

    // Glyphs, knocked out and optically centred on their ink bounds, snapped to the pixel grid.
    let line = fittedGlyphLine(in: cg)
    let ink = CTLineGetImageBounds(line, cg)
    func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    let x = snap((size.width - ink.width) / 2 - ink.minX)
    let y = snap((size.height - ink.height) / 2 - ink.minY)
    cg.textPosition = CGPoint(x: x, y: y)
    cg.setBlendMode(.destinationOut)
    CTLineDraw(line, cg)

    guard let image = cg.makeImage() else { fatalError("cannot snapshot bitmap") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = size
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png encoding failed") }
    return data
}

/// Nearest-neighbour enlargement of `rep` over a backdrop, tinted like a template icon.
func preview(_ rep: NSBitmapImageRep, factor: Int, dark: Bool) -> Data {
    let w = rep.pixelsWide * factor, h = rep.pixelsHigh * factor
    guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("preview bitmap") }
    let ink: (CGFloat, CGFloat, CGFloat) = dark ? (0.92, 0.92, 0.92) : (0.1, 0.1, 0.1)
    let paper: (CGFloat, CGFloat, CGFloat) = dark ? (0.16, 0.16, 0.18) : (0.96, 0.96, 0.96)
    for py in 0..<h {
        for px in 0..<w {
            let alpha = rep.colorAt(x: px / factor, y: py / factor)?.alphaComponent ?? 0
            let c = NSColor(deviceRed: paper.0 + (ink.0 - paper.0) * alpha, green: paper.1 + (ink.1 - paper.1) * alpha,
                            blue: paper.2 + (ink.2 - paper.2) * alpha, alpha: 1)
            out.setColor(c, atX: px, y: py)
        }
    }
    return png(out)
}

let reps = [render(scale: 1), render(scale: 2)]
let work = FileManager.default.temporaryDirectory.appending(path: "duo-menu-icon-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let one = work.appending(path: "MenuIcon.png"), two = work.appending(path: "MenuIcon@2x.png")
try png(reps[0]).write(to: one)
try png(reps[1]).write(to: two)

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", one.path, two.path, "-out", outPath]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { fatalError("tiffutil failed (\(tiffutil.terminationStatus))") }
print("wrote \(outPath)")

if let previewDir {
    try FileManager.default.createDirectory(atPath: previewDir, withIntermediateDirectories: true)
    for (rep, label) in zip(reps, ["1x", "2x"]) {
        for dark in [false, true] {
            let url = URL(fileURLWithPath: previewDir).appending(path: "menu-icon-\(label)-\(dark ? "dark" : "light").png")
            try preview(rep, factor: label == "1x" ? 16 : 8, dark: dark).write(to: url)
            print("preview \(url.path)")
        }
    }
}
