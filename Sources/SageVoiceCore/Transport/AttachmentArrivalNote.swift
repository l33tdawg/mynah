import Foundation

/// What the model is told when the owner sends a file.
///
/// ## Two fabrications, in opposite directions
///
/// The first was silence. Handed a caption with no picture — which is what
/// every hosted backend receives, because only `OllamaClient` reads
/// `BrainMessage.images` — a model answers the only way it can: *"I can't see
/// an image attached to this message, nothing came through."* The owner watched
/// Signal upload a photo and was told it never arrived. The model was not lying;
/// it was never told. So the transcript carries the facts it was missing.
///
/// The second was the apology those facts produced. Told it could not see the
/// picture, Mynah offered to be told what was in it, or to switch to a local
/// model in Settings so it could look — a paragraph of remediation for a thing
/// nobody had asked for:
///
/// > attachments aren't meant to be read by the agent but just stored for later
/// > surfacing … keep these ferry tickets and send them back to me when i ask
///
/// ## The rule is the file type, not the backend
///
/// Backend capability was the wrong axis, and the owner supplied the right one:
///
/// > if i drop a png jpg other image type; then try and interpret it / read it -
/// > if its pdf, docx, xls - keep it for later retrieval
///
/// Which is a better rule than "do whatever this brain is capable of", because
/// it matches why somebody sends the thing. A photo is sent to be *looked at* —
/// what is this plant, what does this error say — so failing to look at one is
/// a real gap and worth stating plainly. A booking confirmation is sent to be
/// *kept*, and a model that reads it out is answering a question nobody asked.
///
/// So a document gets no apology and no description at any capability, and an
/// image gets described wherever that is possible. Neither offers to
/// reconfigure the appliance.
///
/// ## Why the title and not the filename
///
/// `send_file` takes a title, so the one useful thing to say back is the name
/// the owner will need to ask for it later — "saved as *ferry booking*" rather
/// than `here-s-the-ferry-booking-please-store-it-4ee798.jpg`. Naming the file
/// on disk tells them where it went; naming the title tells them how to get it.
enum AttachmentArrivalNote {

    /// One thing that arrived.
    struct Arrival: Equatable {
        /// What it is filed under, in the owner's words.
        let title: String
        /// A picture to look at, rather than a document to keep.
        let isImage: Bool

        init(title: String, isImage: Bool) {
            self.title = title
            self.isImage = isImage
        }
    }

    /// - Parameter seesImages: whether the brain answering this turn reads
    ///   `BrainMessage.images`. See `BrainBackend.seesImages`, whose default is
    ///   deliberately `false`. Irrelevant to documents, which are never read.
    static func text(_ arrivals: [Arrival], seesImages: Bool) -> String? {
        guard !arrivals.isEmpty else { return nil }

        let images = arrivals.filter(\.isImage)
        let documents = arrivals.filter { !$0.isImage }

        var parts: [String] = []
        if !images.isEmpty {
            parts.append(sentence(for: images, noun: "image", seesImages: seesImages))
        }
        if !documents.isEmpty {
            parts.append(sentence(for: documents, noun: "file", seesImages: seesImages))
        }
        return "[" + parts.joined(separator: " ") + "]"
    }

    private static func sentence(for arrivals: [Arrival], noun: String, seesImages: Bool) -> String {
        let count = arrivals.count == 1 ? "an \(noun)" : "\(arrivals.count) \(noun)s"
        let saved = "The owner sent \(count), already saved as \(named(arrivals)) and sendable"
            + " back with \(NotesToolSource.sendToolName) whenever they ask."

        guard noun == "image" else {
            // **No apology and no reading, at any capability.** They sent it to
            // be kept. A model that summarises their booking confirmation has
            // answered a question nobody asked, and one that says sorry for not
            // summarising it is worse.
            return saved + " It is kept for later, not for reading: do not describe what is in"
                + " it or guess at it. Say it is saved under that title, in one line."
        }
        guard !seesImages else {
            // Sent to be looked at, so look properly: he photographs things to
            // find out what they are.
            return saved + " You can see it — say what it is, specifically."
        }
        // The one case where the limitation is worth stating, because looking is
        // what they wanted. Said flatly and once: not an apology, not an offer
        // to reconfigure anything.
        return saved + " You have NOT seen it — this brain does not read pictures. Say so plainly"
            + " in one line. Do not describe it, do not guess what is in it, do not say it failed"
            + " to arrive, and do not offer to switch models."
    }

    /// One caption over three photos writes one note, so the titles arrive
    /// repeated. Saying the same name three times reads as three separate
    /// things, and would have the owner asking for a file that does not exist.
    private static func named(_ arrivals: [Arrival]) -> String {
        var seen = Set<String>()
        return arrivals
            .map(\.title)
            .filter { seen.insert($0).inserted }
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
    }
}
