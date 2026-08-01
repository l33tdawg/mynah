#!/usr/bin/env bash
# Draws Mynah.icns from scratch.
#
# The icon is code, not a binary someone dropped in a folder: a designer can
# read the curves, a reviewer can diff them, and nobody has to keep a .sketch
# file alive to change the beak. The mark is a mynah in profile — near-black
# plumage, one warm-yellow patch behind the eye, which is the bird's actual
# field mark and the app's only accent colour.
#
# Run after changing the drawing, then commit resources/Mynah.icns:
#   scripts/make-icon.sh
#
# Optional: scripts/make-icon.sh /somewhere/else/Mynah.icns
#
# NOT byte-reproducible, and do not spend a day trying to make it so. Two runs
# on the same machine from the same source produce an icns that differs in
# about 5% of pixels at the 512 and 1024 sizes, by at most 1/255 in one channel
# — measured, not assumed. Rendering twice inside a single run is identical, so
# the variance is per-process, and it is the shadow blur landing on a different
# code path. It is invisible. The practical consequence is only that a
# pointless re-run shows up as a 1.4 MB diff, so re-run this when the drawing
# changed and not otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/resources/Mynah.icns}"

command -v swift >/dev/null || { echo "swift not found — install Xcode command line tools." >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil not found — install Xcode command line tools." >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mynah-icon.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ICONSET="$TMP/Mynah.iconset"
mkdir -p "$ICONSET"

cat > "$TMP/draw.swift" <<'SWIFT'
import AppKit
import SwiftUI

// The 1024 design canvas is not the icon. macOS 11+ app icons are a 824pt
// rounded tile centred in a 1024pt canvas; the ~100pt margin is where the
// tile's own drop shadow lives, and it is why a correctly built Mac icon sits
// at the same optical size as Finder and Safari in the Dock. QuietType's
// donor SVG fills all 1024 with the *iOS* corner ratio, which is why it looks
// a size too big next to Apple's own icons.
let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 90, width: 824, height: 824)
let tileRadius: CGFloat = 185

// Plumage, and the one accent. `accent.fill` from the app's palette.
let plumageLight: UInt32 = 0x232323
let plumageDark: UInt32 = 0x000000
let eyePatch: UInt32 = 0xF0A020

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// The macOS squircle. `.continuous`, never `.circular` — at radius 185 the
/// difference between the two is the difference between an app and an Apple
/// app, and it is the one corner in this file that anyone will consciously see.
struct Tile: InsettableShape {
    var inset: CGFloat = 0

    func path(in _: CGRect) -> Path {
        Path(
            roundedRect: tile.insetBy(dx: inset, dy: inset),
            cornerRadius: tileRadius - inset,
            style: .continuous
        )
    }

    func inset(by amount: CGFloat) -> Tile { Tile(inset: inset + amount) }
}

/// A mynah in profile, head and shoulders, facing right.
///
/// Drawn as a portrait bust that runs off the bottom of the tile rather than a
/// silhouette floating in the middle: the crop is what lets the head be large
/// enough to survive 16pt, and it removes the "sticker dropped on a square"
/// look that a centred mark has at every size.
struct MynahMark: Shape {
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 516, y: 248))                                    // crown
        p.addCurve(to: CGPoint(x: 652, y: 330),                                // brow
                   control1: CGPoint(x: 592, y: 248), control2: CGPoint(x: 628, y: 286))
        p.addCurve(to: CGPoint(x: 686, y: 386),                                // forehead
                   control1: CGPoint(x: 670, y: 348), control2: CGPoint(x: 682, y: 370))
        p.addCurve(to: CGPoint(x: 846, y: 446),                                // upper mandible
                   control1: CGPoint(x: 762, y: 388), control2: CGPoint(x: 816, y: 414))
        p.addCurve(to: CGPoint(x: 688, y: 484),                                // lower mandible
                   control1: CGPoint(x: 818, y: 478), control2: CGPoint(x: 756, y: 490))
        p.addCurve(to: CGPoint(x: 652, y: 570),                                // chin, throat
                   control1: CGPoint(x: 672, y: 514), control2: CGPoint(x: 658, y: 542))
        p.addCurve(to: CGPoint(x: 776, y: 786),                                // breast
                   control1: CGPoint(x: 646, y: 660), control2: CGPoint(x: 716, y: 722))
        // The last points on each side sit outside the tile on purpose: the
        // clip does the cropping, so the bust reaches the rounded bottom
        // corners instead of leaving a pale crescent under each shoulder.
        p.addCurve(to: CGPoint(x: 946, y: 1000),                               // right shoulder
                   control1: CGPoint(x: 840, y: 842), control2: CGPoint(x: 906, y: 906))
        p.addLine(to: CGPoint(x: 92, y: 1000))
        p.addCurve(to: CGPoint(x: 256, y: 776),                                // left shoulder
                   control1: CGPoint(x: 128, y: 902), control2: CGPoint(x: 194, y: 828))
        p.addCurve(to: CGPoint(x: 346, y: 600),                                // nape
                   control1: CGPoint(x: 296, y: 730), control2: CGPoint(x: 336, y: 668))
        p.addCurve(to: CGPoint(x: 322, y: 430),                                // back of head
                   control1: CGPoint(x: 350, y: 540), control2: CGPoint(x: 322, y: 486))
        p.addCurve(to: CGPoint(x: 516, y: 248),                                // crown
                   control1: CGPoint(x: 322, y: 336), control2: CGPoint(x: 404, y: 248))
        p.closeSubpath()
        return p
    }
}

/// The common mynah's bare yellow skin, which sits behind the eye and tapers
/// toward the nape. Drawn rather than an ellipse: the taper is the whole
/// difference between a field mark and a cartoon eye.
struct EyePatch: Shape {
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 692, y: 380))
        p.addCurve(to: CGPoint(x: 682, y: 452),
                   control1: CGPoint(x: 710, y: 406), control2: CGPoint(x: 704, y: 438))
        p.addCurve(to: CGPoint(x: 540, y: 428),
                   control1: CGPoint(x: 636, y: 466), control2: CGPoint(x: 578, y: 450))
        p.addCurve(to: CGPoint(x: 692, y: 380),
                   control1: CGPoint(x: 562, y: 388), control2: CGPoint(x: 628, y: 368))
        p.closeSubpath()
        return p
    }
}

struct IconView: View {
    /// False below 32px, where a 46pt pupil lands on less than one and a half
    /// pixels and turns the yellow patch to mud. Dropping it there leaves a
    /// clean dark head with a yellow flash, which is what the eye resolves at
    /// that size anyway.
    var drawsPupil: Bool

    var body: some View {
        ZStack {
            Tile()
                .fill(LinearGradient(
                    colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF1F0ED)],
                    startPoint: UnitPoint(x: 0.18, y: 0.12),
                    endPoint: UnitPoint(x: 0.80, y: 0.88)
                ))
                .shadow(color: .black.opacity(0.16), radius: 20, y: 12)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

            ZStack {
                MynahMark()
                    .fill(LinearGradient(
                        colors: [Color(hex: plumageLight), Color(hex: plumageDark)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                EyePatch().fill(Color(hex: eyePatch))
                if drawsPupil {
                    Circle()
                        .fill(Color(hex: 0x0E1113))
                        .frame(width: 48, height: 48)
                        .position(x: 662, y: 408)
                }
            }
            // Without the compositing group the shadow is drawn per shape, so
            // the pupil casts its own and the patch gets a dark rim.
            .compositingGroup()
            .shadow(color: .black.opacity(0.20), radius: 28, y: 18)
            .clipShape(Tile())

            // Last, so it is a single hairline. The donor app stacks two
            // strokes on one rectangle and gets a muddy double edge.
            Tile().strokeBorder(Color(hex: 0xDCDAD5, alpha: 0.55), lineWidth: 2)
        }
        .frame(width: canvas, height: canvas)
    }
}

@MainActor
func render(pixels: Int, to url: URL) throws {
    let renderer = ImageRenderer(content: IconView(drawsPupil: pixels >= 32))
    // Rendering the vector at each size rather than downscaling one 1024 PNG.
    // Downscaling softens the 16 and 32pt variants, which are the two sizes a
    // person actually spends their day looking at.
    renderer.scale = CGFloat(pixels) / canvas
    renderer.isOpaque = false
    guard let image = renderer.cgImage else {
        throw Failure("could not render \(pixels)px")
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw Failure("could not encode \(pixels)px as PNG")
    }
    try data.write(to: url)
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// name -> pixel size. Every slot `iconutil` wants; a missing one makes macOS
// scale a neighbour and the Dock icon goes soft.
let slots: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    try MainActor.assumeIsolated {
        for (name, pixels) in slots {
            try render(pixels: pixels, to: iconset.appendingPathComponent("\(name).png"))
        }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
SWIFT

echo "Drawing iconset…"
swift "$TMP/draw.swift" "$ICONSET"

# Every slot present, or the Dock scales a neighbour and the icon goes soft.
COUNT="$(find "$ICONSET" -name '*.png' | wc -l | tr -d ' ')"
if [[ "$COUNT" != "10" ]]; then
  echo "Expected 10 PNGs in the iconset, got $COUNT." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
iconutil --convert icns --output "$OUT" "$ICONSET"

# iconutil exits 0 on some malformed input, so confirm the file is really an
# icns rather than trusting the exit status.
if ! file -b "$OUT" | grep -qi "Mac OS X icon"; then
  echo "iconutil produced something that is not an icns: $OUT" >&2
  exit 1
fi

echo "$OUT"
