import Foundation
import SwiftUI

/// Turns the bare URLs in a chat message into links you can click.
///
/// Mynah answers with plain text — it searched the web and it is telling you
/// where it looked. Rendered through `Text(String)` that arrives as characters
/// and nothing else, so the owner's only way to follow a link their appliance
/// just found for them is to select it, copy it, switch to a browser and paste.
/// For a two-line URL that wraps mid-path, selecting it accurately is itself the
/// hard part.
///
/// ## Why a detector and not markdown
///
/// `Text` renders markdown when handed a `LocalizedStringKey`, which would make
/// `[label](url)` clickable — but the text here is not ours. It is whatever the
/// model wrote, it contains bare URLs rather than markdown link syntax, and
/// routing arbitrary model output through a *localisation key* would also let
/// stray brackets and underscores silently restyle or delete parts of an
/// answer. `NSDataDetector` reads the string as prose and finds the URLs in it,
/// which is the actual problem.
///
/// ## Why only three schemes
///
/// The text is untrusted: it is model output, and a model can be talked into
/// writing anything. A link is the one thing in this window that acts on a
/// click, so it is the one thing worth being narrow about. `http`, `https` and
/// `mailto` are what a chat answer legitimately contains. Everything else —
/// `file://` pointing into the owner's disk being the one that matters — stays
/// plain text, still fully readable, just not armed.
enum ChatLinks {

    /// The message, with its URLs made clickable and nothing else changed.
    ///
    /// Underlined, and *not* recoloured. This palette has no hue in it by
    /// decision — `Palette.accent.ink` is full-strength ink precisely because
    /// "with the hue gone there is nothing left to darken" — so a blue link
    /// would be the first colour in the product and would arrive by accident,
    /// through a helper, rather than by anybody choosing it. An underline is
    /// the older affordance anyway, and it survives being read by someone who
    /// cannot see the colour.
    static func attributed(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return attributed }

        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, range: whole) {
            guard let url = match.url, isFollowable(url) else { continue }
            guard let inText = Range(match.range, in: text),
                  let inAttributed = Range(inText, in: attributed) else { continue }
            attributed[inAttributed].link = url
            attributed[inAttributed].underlineStyle = .single
        }
        return attributed
    }

    /// Whether a click on this is allowed to leave the window.
    ///
    /// Checked against the parsed `URL`'s scheme rather than the text, so a
    /// label that reads like one thing and resolves to another is judged on
    /// what it resolves to.
    static func isFollowable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}
