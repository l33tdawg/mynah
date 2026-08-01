#!/usr/bin/env bash
# Draws docs/og.png — the 1200x630 card that link previews show.
#
# The bird is NOT redrawn here. It is extracted from the icon this app already
# ships, so there is exactly one drawing of the mark in the repository and no way
# for a link preview to show a bird the app does not have. Change the icon in
# scripts/make-icon.sh, re-run that, then re-run this.
#
#   scripts/make-og-image.sh
#
# 1200x630 is what Open Graph consumers crop to; anything else gets letterboxed
# or cut by whichever service is rendering it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICNS="$ROOT/resources/Mynah.icns"
OUT="${1:-$ROOT/docs/og.png}"

command -v swift >/dev/null || { echo "swift not found — install Xcode command line tools." >&2; exit 1; }
[[ -f "$ICNS" ]] || { echo "No icon at $ICNS. Run scripts/make-icon.sh first." >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mynah-og.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The largest representation in the icns, so the card is drawn from real pixels
# rather than an upscale.
sips -s format png "$ICNS" --out "$TMP/bird.png" >/dev/null 2>&1 \
  || { echo "Could not read $ICNS" >&2; exit 1; }

cat > "$TMP/draw.swift" <<'SWIFT'
import AppKit

let birdPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

let width = 1200, height = 630

// Straight from docs/index.html's :root. If the site's palette moves, this has
// to move with it — a preview card in last season's colours reads as somebody
// else's page.
let canvas = NSColor(srgbRed: 0.957, green: 0.957, blue: 0.965, alpha: 1)   // #F4F4F6
let ink1 = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.88)
let ink2 = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.56)
let hairline = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09)

guard let bird = NSImage(contentsOfFile: birdPath) else {
    FileHandle.standardError.write(Data("could not load the icon\n".utf8))
    exit(1)
}

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
guard let context = NSGraphicsContext.current else { exit(1) }
context.imageInterpolation = .high

canvas.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let margin: CGFloat = 76

// A hairline down near the base, the same weight the site uses between rows.
// Keeps the card from reading as a floating word on an empty field.
hairline.setFill()
NSRect(x: margin, y: 84, width: CGFloat(width) - margin * 2, height: 1).fill()

let birdSide: CGFloat = 132
bird.draw(
    in: NSRect(x: margin, y: CGFloat(height) - margin - birdSide, width: birdSide, height: birdSide),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)

// Every block is measured and then placed by its TOP edge, counting down from
// the top of the card. AppKit's origin is bottom-left and a wrapping headline's
// height is not known in advance, so laying out by eye in bottom-up coordinates
// silently overlaps — which is exactly what the first version of this did.
func measure(_ text: String, _ font: NSFont, width: CGFloat) -> (NSAttributedString, CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineHeightMultiple = 1.06
    let string = NSAttributedString(string: text, attributes: [
        .font: font, .paragraphStyle: style
    ])
    let bounds = string.boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin]
    )
    return (string, ceil(bounds.height))
}

@discardableResult
func place(
    _ text: String, _ font: NSFont, _ colour: NSColor,
    x: CGFloat, topDown: CGFloat, width: CGFloat
) -> CGFloat {
    let (_, blockHeight) = measure(text, font, width: width)
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    style.lineHeightMultiple = 1.06
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: colour, .paragraphStyle: style
    ])
    attributed.draw(
        with: NSRect(
            x: x,
            y: CGFloat(height) - topDown - blockHeight,
            width: width,
            height: blockHeight
        ),
        options: [.usesLineFragmentOrigin]
    )
    return topDown + blockHeight
}

// The wordmark sits on the bird's optical centre rather than its box centre.
place("MYNAH", .systemFont(ofSize: 22, weight: .semibold), ink2,
      x: margin + birdSide + 24, topDown: margin + birdSide / 2 - 16, width: 400)

var cursor = margin + birdSide + 56
cursor = place("Tell it once. Reach it anywhere.",
               .systemFont(ofSize: 64, weight: .bold), ink1,
               x: margin, topDown: cursor, width: CGFloat(width) - margin * 2)

place("Runs on your Mac. Remembers across conversations. Answers in Signal.",
      .systemFont(ofSize: 26, weight: .regular), ink2,
      x: margin, topDown: cursor + 26, width: 880)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode the card\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
SWIFT

swift "$TMP/draw.swift" "$TMP/bird.png" "$OUT"
echo "$OUT"
