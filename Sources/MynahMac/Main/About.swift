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

    /// Where to write when something is wrong.
    ///
    /// The repository records no support address — the only address in the tree
    /// is a placeholder in an example — so this is the author's own, which is
    /// the honest answer for an appliance with one person behind it.
    static let supportEmail = "dhillon.andrew@gmail.com"

    /// SAGE is public and Apache 2.0, so this link works for whoever is holding
    /// the app.
    ///
    /// There is deliberately no link to this project's own repository. It is
    /// private, and the people the owner hands this appliance to cannot open it
    /// — a row that looks like a link and delivers a 404 is worse than no row,
    /// and this app already refuses to draw controls that quietly do nothing.
    static let sageURL = URL(string: "https://github.com/l33tdawg/sage")!

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
