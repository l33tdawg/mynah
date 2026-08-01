import SwiftUI

/// A stable colour per subject, for telling one apart from another at a glance.
///
/// **This is the first hue in the product that does not mean anything**, and the
/// distinction is the whole reason it is allowed.
///
/// `Palette.state` colours are *state*: green is "stays on this Mac", amber is
/// "words leave this Mac", red is "this failed". `AmberIsGoneTests` exists
/// because a colour that meant four things at once got read as a fifth — the
/// owner saw a yellow mark on a stale task list and reported that Signal had
/// crashed. It had not.
///
/// A subject tint means **identity**, the way a person's initials do. It says
/// "these two rows are filed in the same place" and nothing else: nothing good,
/// nothing wrong, nothing to act on. That is a different axis from state, and
/// the two must not be confusable — which is a constraint on the hues rather
/// than a note in a comment:
///
/// - Nothing in the **red or amber** band (0°–60°), which would read as a
///   warning on a row that is fine.
/// - Nothing in the **green** band (95°–165°), which would read as the
///   "stays on this Mac" promise being made about a subject.
///
/// What is left is cyan through violet to magenta, which is plenty for telling
/// six or seven subjects apart and cannot be mistaken for a verdict.
///
/// Kept muted on purpose. These sit behind the sentence the owner came to read,
/// and a saturated chip beside body text is the thing that makes an app look
/// like a control panel — which `SettingsRow` already declines to be.
enum SubjectTint {

    /// The hues, in degrees. Six, because a seventh starts to look like a
    /// sixth — the point is telling subjects apart, not enumerating them.
    ///
    /// Ordered so that adjacent entries are not adjacent hues: with a hash
    /// picking the index, two subjects that land next to each other in the
    /// table are as likely to be shown together as any other pair, and
    /// 190° beside 200° is two chips that look the same.
    static let hues: [Double] = [212, 280, 190, 320, 250, 300]

    /// Which hue a subject gets. Deterministic across launches and machines.
    static func hueDegrees(for subject: String) -> Double {
        hues[Int(stableHash(subject) % UInt64(hues.count))]
    }

    /// The chip's text.
    static func ink(for subject: String) -> Color {
        let hue = hueDegrees(for: subject) / 360
        return Color.mynah(
            // Dark enough on a white card to clear contrast on 12pt text, which
            // is what the chip's label is.
            light: NSColor(hue: hue, saturation: 0.72, brightness: 0.52, alpha: 1),
            dark: NSColor(hue: hue, saturation: 0.46, brightness: 0.90, alpha: 1)
        )
    }

    /// The chip itself. Low alpha so it reads as a tint rather than a button —
    /// a subject is not something to press.
    static func wash(for subject: String) -> Color {
        let hue = hueDegrees(for: subject) / 360
        return Color.mynah(
            light: NSColor(hue: hue, saturation: 0.62, brightness: 0.62, alpha: 0.14),
            dark: NSColor(hue: hue, saturation: 0.52, brightness: 0.72, alpha: 0.20)
        )
    }

    /// FNV-1a over the UTF-8 bytes.
    ///
    /// **Not `hashValue`.** Swift seeds `Hashable` per process, so the same
    /// subject would draw blue this launch and magenta the next — which is
    /// worse than no colour at all, because the owner would have learned
    /// something that then stopped being true. This is the one property of the
    /// tint that has to hold, and it is the one a reasonable person assumes.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            // 0x100000001b3. Grouped carefully: an extra zero here is still a
            // perfectly good hash, just not this one, and the test that pins
            // the two reference vectors is what caught it.
            hash &*= 0x100_0000_01b3
        }
        return hash
    }
}
