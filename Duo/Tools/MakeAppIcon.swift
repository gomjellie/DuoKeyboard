// Generates Duo/Resources/AppIcon.icon (Icon Composer format, ui-design §4) from code.
//
// Two overlapping Liquid Glass keycaps: a warm one with 가 behind, a cool one with A in front.
// The glyphs are stroke geometry outlined with CGPath — no font outlines, so no licence questions.
//
// Usage (from the repo root):
//   swift Duo/Tools/MakeAppIcon.swift Duo/Resources
//   ictool Duo/Resources/AppIcon.icon --export-image --output-file icon.png --platform macOS \
//          --rendition Default --width 512 --height 512 --scale 1
import CoreGraphics
import Foundation

// MARK: Geometry (SVG space: 1024 × 1024, y grows down)

/// 가: ㄱ (top bar, then a descender sweeping down-left) and ㅏ (tall stem with a short tick).
func hangulGa(center c: CGPoint, scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    // ㄱ
    p.move(to: pt(-118, -84))
    p.addLine(to: pt(-6, -84))
    p.addCurve(to: pt(-112, 108), control1: pt(-6, 4), control2: pt(-42, 66))
    // ㅏ
    p.move(to: pt(62, -128))
    p.addLine(to: pt(62, 128))
    p.move(to: pt(62, -4))
    p.addLine(to: pt(124, -4))
    return p
}

/// A: two legs meeting at the apex and a crossbar.
func latinA(center c: CGPoint, scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    p.move(to: pt(-98, 118))
    p.addLine(to: pt(0, -118))
    p.addLine(to: pt(98, 118))
    p.move(to: pt(-58, 40))
    p.addLine(to: pt(58, 40))
    return p
}

func outline(_ path: CGPath, width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        .normalized() // merge overlaps so a nonzero fill never punches holes
}

func roundedTile(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: SVG

func svgPathData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
    path.applyWithBlock { element in
        let e = element.pointee
        let p = e.points
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

// MARK: Document

let resources = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
let iconDir = resources.appendingPathComponent("AppIcon.icon", isDirectory: true)
let assets = iconDir.appendingPathComponent("Assets", isDirectory: true)
try? FileManager.default.removeItem(at: iconDir)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// Two keycaps on the diagonal: 가 (back, upper left) and A (front, lower right).
let tileSize: CGFloat = 430
let radius: CGFloat = 116
let backRect = CGRect(x: 150, y: 156, width: tileSize, height: tileSize)
let frontRect = CGRect(x: 444, y: 438, width: tileSize, height: tileSize)
let files: [String: CGPath] = [
    "tile-hangul.svg": roundedTile(backRect, radius: radius),
    "glyph-hangul.svg": outline(hangulGa(center: CGPoint(x: backRect.midX - 4, y: backRect.midY - 2), scale: 1.0), width: 42),
    "tile-latin.svg": roundedTile(frontRect, radius: radius),
    "glyph-latin.svg": outline(latinA(center: CGPoint(x: frontRect.midX, y: frontRect.midY + 2), scale: 1.0), width: 44),
]
for (name, path) in files {
    try svg(path).write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// groups[0] is the top-most group; layers[0] the top-most layer of a group (ui-design §4.1).
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
