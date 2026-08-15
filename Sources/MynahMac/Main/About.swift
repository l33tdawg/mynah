import Foundation

// MARK: - Who else built this

/// One piece of somebody else's work that Mynah ships or runs on.
///
/// `licence` is displayed verbatim and is the one field here that carries legal
/// weight, so nothing goes in it that was not read off the project's own LICENSE
/// file. `role` is what it does for the owner, not what it is — "carries messages
/// to and from your phone" rather than "JSON-RPC client".
struct Attribution: Identifiable, Sendable, Equatable {
    var name: String
    var role: String
    var licence: String
    var url: URL

    /// Set where the licence obliges the recipient to be told something, rather
    /// than merely credited.
    ///
    /// Most licences here are satisfied by naming the component. A copyleft one
    /// is not: handing somebody a build that contains it means they are entitled
    /// to its source, and a link is what discharges that. Carried on the entry
    /// rather than written into the view, so the obligation travels with the
    /// component it belongs to and cannot be lost when the layout changes.
    var sourceOffer: String?

    var id: String { name }
}

/// The facts an About panel exists to carry.
///
/// Versions are deliberately absent from this file. Mynah's own comes from the
/// bundle and SAGE's is read off the copy actually inside it, because a number
/// typed here is a number that goes stale on the next release and nobody
/// notices — the vendored SAGE was already a version behind the one this was
/// first written against.
enum MynahAbout {

    /// Whose product this is.
    ///
    /// It was nowhere in the interface. The owner's name appeared in the tree
    /// exactly twice — as a support address and inside a GitHub URL — and he
    /// asked for it, which is a reasonable thing to want on the thing you made.
    ///
    /// Read off the repository's own `LICENSE` (`Copyright 2026 Dhillon Andrew
    /// Kannabhiran`) rather than typed from memory, and deliberately no company,
    /// no tagline and no year *range*: the file says one year and this says the
    /// same one.
    static let author = "Dhillon Andrew Kannabhiran"

    /// The line an About panel carries under the name.
    ///
    /// `LICENSE` is Apache 2.0 and now actually ships inside the bundle —
    /// `package-app.sh` copies it, which it did not before, so `Info.plist`'s
    /// long-standing "see the LICENSE file included with this app" stopped being
    /// a claim about a file that was not there.
    static let copyright = "Copyright © 2026 Dhillon Andrew Kannabhiran. Apache 2.0 licensed."

    /// Where to write when something is wrong.
    static let supportEmail = "l33tdawg@hackinthebox.org"

    /// SAGE is public and Apache 2.0, so this link works for whoever is holding
    /// the app. Mynah is built on it and stores everything it remembers there,
    /// so it is the one link worth carrying whatever else changes.
    static let sageURL = URL(string: "https://github.com/l33tdawg/sage")!

    /// Mynah's own repository.
    ///
    /// This used to be deliberately absent: the repository was private, and a
    /// row that looks like a link and delivers a 404 is worse than no row. It is
    /// public as of 1.2.0, so the reason is spent and the link is real.
    static let projectURL = URL(string: "https://github.com/l33tdawg/mynah")!

    /// Everything third-party that reaches the owner, with the licence each was
    /// verified under.
    ///
    /// Verified by reading each project's own LICENSE at the version shipped,
    /// not from memory. Ordered by how close each sits to something the owner
    /// can point at, so the list reads as a description of the appliance rather
    /// than a bill of materials.
    ///
    /// Nothing is listed here that is not actually shipped or actually required
    /// to run. Padding an attribution list with plausible dependencies makes the
    /// whole list unreliable, and the parts of it that matter are the parts
    /// somebody may one day have to rely on.
    static let components: [Attribution] = [
        // The one component whose licence asks for more than credit. Mynah runs
        // it as a separate process and talks to it over a socket, so nothing of
        // Mynah's own becomes copyleft — but the binary is distributed inside
        // this app, and whoever receives it is entitled to its source.
        Attribution(
            name: "signal-cli",
            role: "Carries messages between Mynah and your phone.",
            licence: "GPL 3.0",
            url: URL(string: "https://github.com/AsamK/signal-cli")!,
            sourceOffer: "Bundled unmodified. Its source is at the link above, "
                + "and is available from us on request."
        ),
        // **Named because it is GPL-3.0 and it ships.** Everything else in the
        // WhatsApp column of this list is MIT, and this entry used to be absent
        // — which made the screen say, by omission, that the whole WhatsApp side
        // was permissive. It is not, and the owner is the one who would be
        // conveying it.
        //
        // The source offer is the obligation, not the courtesy: GPL-3.0 needs
        // the corresponding source to be available for as long as the build is
        // distributed. See NOTICE for why conveying it does not make Mynah
        // itself copyleft — the bridge is a separate process.
        Attribution(
            name: "libsignal",
            role: "The encryption WhatsApp itself uses, inside the WhatsApp "
                + "bridge. It arrives as a dependency of Baileys.",
            licence: "GPL 3.0",
            url: URL(string: "https://www.npmjs.com/package/libsignal")!,
            sourceOffer: "Bundled unmodified, in Contents/Resources/whatsapp/node_modules. "
                + "Its complete source is at the link above, and is available from us on request."
        ),
        Attribution(
            name: "WhisperKit",
            role: "Turns your voice notes into words on this Mac's Neural Engine, "
                + "and converted the speech models to run there.",
            licence: "MIT",
            url: URL(string: "https://github.com/argmaxinc/argmax-oss-swift")!
        ),
        Attribution(
            name: "Whisper",
            role: "The speech models themselves, from OpenAI.",
            licence: "Apache 2.0",
            url: URL(string: "https://huggingface.co/openai/whisper-large-v3")!
        ),
        Attribution(
            name: "Kokoro",
            role: "The natural voice on a call. Installed separately, and calls "
                + "fall back to the macOS voice without it.",
            licence: "Apache 2.0",
            url: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M")!
        ),
        Attribution(
            name: "kokoro-onnx",
            role: "Runs that voice on this Mac.",
            licence: "MIT",
            url: URL(string: "https://github.com/thewh1teagle/kokoro-onnx")!
        ),
        Attribution(
            name: "Pion",
            role: "Holds the call open between your phone and this Mac.",
            licence: "MIT",
            url: URL(string: "https://github.com/pion/webrtc")!
        ),
        Attribution(
            name: "Opus",
            role: "Compresses what is said in both directions on a call.",
            licence: "BSD 3-Clause",
            url: URL(string: "https://opus-codec.org")!
        ),
        Attribution(
            name: "swift-transformers",
            role: "Inside WhisperKit, from Hugging Face.",
            licence: "Apache 2.0",
            url: URL(string: "https://github.com/huggingface/swift-transformers")!
        ),
        Attribution(
            name: "Go x/crypto and x/net",
            role: "Secures and carries the call endpoint's connections.",
            licence: "BSD 3-Clause",
            url: URL(string: "https://pkg.go.dev/golang.org/x/crypto")!
        ),
        Attribution(
            name: "google/uuid",
            role: "Names each call.",
            licence: "BSD 3-Clause",
            url: URL(string: "https://github.com/google/uuid")!
        ),
    ]
}
