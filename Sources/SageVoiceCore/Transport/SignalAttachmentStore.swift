#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Keeps what the owner sends, whatever the brain can do with it.
///
/// ## The failure this ends
///
/// The owner sent a ferry ticket and asked Mynah to store it. The daemon found
/// the attachment, read 94KB off disk and encoded it — and the reply was *"I
/// can't see an image attached to this message — nothing came through."*
///
/// Every part of that sentence was wrong, and it was wrong in the worst
/// direction: it told somebody their phone had failed to send a thing their
/// phone had sent. What actually happened is that `BrainMessage.images` was
/// only ever read by `OllamaClient`; every hosted backend accepted the array
/// and dropped it, so the model was handed a caption with no picture and
/// answered the only way it could.
///
/// **Keeping the file was never the brain's job.** The owner's instruction was
/// simple and does not mention models at all:
///
/// > attachments sent via signal should not matter what the backend is if the
/// > user wants it stored, just store it and pull it up when asked
///
/// So storage happens first and unconditionally, before any question about what
/// can look at it.
///
/// ## The second failure, which was worse
///
/// On Linux *every* attachment was dropped, and nobody was told. The private
/// `keep` below threw, its `catch` wrote one line to the daemon log and
/// returned `nil`, and the turn carried on and reported itself handled. The
/// owner sent a PDF, watched it upload, was told the message had been dealt
/// with, and the file was never filed. The log knew; the owner did not.
///
/// Both halves of that are now closed, and they were two separate defects:
///
/// 1. **What threw.** `OwnerOnlyFileSecurity.write` — not the date formatting,
///    which is the thing that looks guilty and is not (see `stamp`).
///    swift-corelibs-foundation implements `FileManager.replaceItemAt` as
///    "move the original aside, move the new one in", so creating a file that
///    does not exist yet throws `NSCocoaErrorDomain 260 "The file doesn't
///    exist."` — about the destination it was asked to create. Measured
///    directly: on swift:6.0-jammy a bare `replaceItemAt` at a fresh path
///    throws 260; the identical call on macOS returns the published URL. Fixed
///    in `OwnerOnlyFileSecurity`, which now publishes with `rename(2)`
///    off-Darwin.
/// 2. **The silence.** `keep` no longer returns a bare list of successes, from
///    which an unkept file is indistinguishable from a file nobody sent. It
///    returns an `Outcome` that names every refusal, and
///    `Outcome.ownerFacingNote` is the sentence that tells the owner which file
///    did not save and what to do about it.
///
/// ## Where it goes, and why not somewhere new
///
/// Into the notes directory the owner already has, beside the notes Mynah
/// writes — not a second filing system with its own retrieval path. `notes_list`
/// and `notes_read` already work there, so "pull up the ferry booking" is
/// answered by machinery that exists rather than machinery invented for
/// attachments.
///
/// Application Support survives an app update: the installer replaces the
/// bundle in `/Applications` and never touches this directory. Kept files are
/// not versioned artefacts and are never cleaned up by a release.
public struct SignalAttachmentStore: Sendable {

    /// Where the bytes go. A subdirectory, so `notes_list` keeps returning
    /// notes rather than a mix of prose and binaries.
    public static let subdirectory = "attachments"

    private let notesDirectory: URL
    private let fileManager: FileManager

    public init(
        notesDirectory: URL = NotesToolSource.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.notesDirectory = notesDirectory
        self.fileManager = fileManager
    }

    /// One kept attachment.
    public struct Kept: Sendable, Equatable {
        /// Where the bytes landed.
        public let file: URL
        /// The note written beside it, which is what search will find.
        public let note: URL
        /// What the owner said when they sent it, if anything.
        public let caption: String?
        /// Whether this is a picture rather than a document, which decides
        /// whether the model is asked to look at it. The owner's rule:
        ///
        /// > if i drop a png jpg other image type; then try and interpret it /
        /// > read it - if its pdf, docx, xls - keep it for later retrieval
        ///
        /// Carried from `SignalAttachment.isImage` rather than re-derived from
        /// the saved filename, so the answer cannot drift from the one
        /// `imageURLs` used when it decided what to show the model.
        public let isImage: Bool
    }

    /// One thing the owner sent that is **not** on disk.
    ///
    /// This type exists because its absence is what made the Linux defect
    /// invisible for a whole platform. A function that returns `[Kept]` and
    /// nothing else cannot distinguish "they sent nothing" from "they sent a
    /// ferry ticket and it is gone", so every caller treated the second as the
    /// first and said nothing.
    public struct Refusal: Sendable, Equatable {
        /// What the owner will recognise it by: the name their phone put on it,
        /// falling back to the name on disk and then to the content type.
        /// **Never a staging path or a hash** — they are being asked to send it
        /// again, and they can only do that for a thing they can name.
        public let name: String
        /// The MIME type, when the channel reported one.
        public let contentType: String?
        /// A photo rather than a document, so the sentence can use the right
        /// noun. Same source as `Kept.isImage`.
        public let isImage: Bool
        /// Why, in full, including the underlying error. **For the log, not for
        /// the owner** — `ownerFacingNote` deliberately does not repeat it,
        /// because a Cocoa error domain in the middle of a chat message is
        /// noise, and a filesystem path is worse than noise.
        public let reason: String
    }

    /// What one call to `keep` did — and, just as important, what it did not do.
    ///
    /// ## Why this is a `Collection` of `Kept`
    ///
    /// So that every existing call site keeps compiling and keeps behaving
    /// exactly as it did — `VoiceBridgeDaemon.keepAttachments` spells this
    /// `batch.flatMap { store.keep(…) }` and gets `[Kept]` out, and the
    /// WhatsApp tests spell it `kept.first?.note`. Changing what those lines
    /// mean is not part of closing this defect.
    ///
    /// **The conformance is a bridge, not the destination.** Iterating an
    /// `Outcome` yields only the successes, which is the exact shape of the
    /// defect above, so anything that iterates one and then speaks to the owner
    /// still owes them `ownerFacingNote`. That is one line at the call site and
    /// it is not this file's to write.
    public struct Outcome: Sendable, Equatable, RandomAccessCollection {
        /// Everything that reached disk, with the note that makes it findable.
        public let kept: [Kept]
        /// Everything that did not, named.
        public let refusals: [Refusal]

        public init(kept: [Kept] = [], refusals: [Refusal] = []) {
            self.kept = kept
            self.refusals = refusals
        }

        public var startIndex: Int { kept.startIndex }
        public var endIndex: Int { kept.endIndex }
        public subscript(position: Int) -> Kept { kept[position] }
        public func index(after i: Int) -> Int { kept.index(after: i) }
        public func index(before i: Int) -> Int { kept.index(before: i) }

        /// What to add to the turn so the owner hears about the file that is
        /// not there. `nil` when everything was kept, which is the normal case
        /// and must stay silent.
        ///
        /// Shaped like `AttachmentArrivalNote.text` — a bracketed instruction
        /// appended to the transcript — because it travels the same way and has
        /// to read as the same kind of aside to the model.
        ///
        /// Three things it insists on, all of them learned from the failure it
        /// replaces:
        ///
        /// - It **names the file**, because "an attachment failed" is not
        ///   actionable when they sent four.
        /// - It **names the next action** — send it again — because a dead end
        ///   with no door is how the owner ends up believing the appliance ate
        ///   their ticket.
        /// - It forbids the model from describing, guessing at, or claiming to
        ///   have saved the thing, because those are precisely the three
        ///   fabrications a model reaches for when it is told a file exists and
        ///   handed no bytes.
        public var ownerFacingNote: String? {
            guard !refusals.isEmpty else { return nil }

            let images = refusals.filter(\.isImage)
            let documents = refusals.filter { !$0.isImage }
            var parts: [String] = []
            if !images.isEmpty {
                parts.append(Self.sentence(for: images, noun: "image"))
            }
            if !documents.isEmpty {
                parts.append(Self.sentence(for: documents, noun: "file"))
            }
            return "[" + parts.joined(separator: " ") + "]"
        }

        private static func sentence(for refusals: [Refusal], noun: String) -> String {
            let one = refusals.count == 1
            // "an image", "a file". `AttachmentArrivalNote` says "an file"
            // here; this is the same sentence read out loud to the owner and it
            // is not going to make that mistake twice.
            let article = "aeiou".contains(noun.lowercased().first ?? "x") ? "an" : "a"
            let count = one ? "\(article) \(noun)" : "\(refusals.count) \(noun)s"
            let subject = one ? "it" : "they"
            let object = one ? "it" : "them"
            let didNotSave = one ? "it was not saved" : "they were not saved"
            let wasSaved = one ? "it was saved" : "they were saved"
            return "The owner sent \(count) that could NOT be saved: \(named(refusals))."
                + " Tell them plainly, in one line, that \(didNotSave) and ask them to send"
                + " \(object) again. Do NOT say \(wasSaved), do NOT describe \(object), and do NOT"
                + " guess what is in \(object) — nothing about \(subject) reached this machine."
        }

        /// One caption over three photos can name the same file three times.
        /// Saying it three times reads as three separate losses.
        private static func named(_ refusals: [Refusal]) -> String {
            var seen = Set<String>()
            return refusals
                .map(\.name)
                .filter { seen.insert($0).inserted }
                .map { "\"\($0)\"" }
                .joined(separator: ", ")
        }
    }

    /// Copies each attachment in and writes one note describing it.
    ///
    /// Never throws. A photo that cannot be copied is worth a refusal the owner
    /// hears about and a turn that carries on — refusing to answer because one
    /// attachment was unreadable would be a worse appliance than one that says
    /// what it kept and what it did not.
    ///
    /// - Parameter via: which app the owner sent it from. It goes into the note,
    ///   and it is the note that search returns — "the ferry booking I sent on
    ///   WhatsApp" only finds anything if the note says WhatsApp. This said
    ///   "Signal" unconditionally, which for a WhatsApp attachment is a
    ///   remembered fact that is simply false.
    /// - Returns: an `Outcome`. Read `Outcome.ownerFacingNote` before telling
    ///   the owner the turn was handled.
    @discardableResult
    public func keep(
        _ attachments: [ChannelAttachment],
        via channel: ChannelKind,
        caption: String?,
        receivedAt: Date,
        log: (String) -> Void = { _ in }
    ) -> Outcome {
        guard !attachments.isEmpty else { return Outcome() }

        let directory = notesDirectory.appendingPathComponent(Self.subdirectory, isDirectory: true)
        do {
            try OwnerOnlyFileSecurity.prepareDirectory(directory)
        } catch {
            // **Every one of them refused, by name.** This returned `[]` — the
            // same value as "they sent nothing" — so a notes directory that
            // could not be created lost the whole batch in silence.
            log(
                "[attachments] could not prepare \(directory.path): \(error)."
                    + " Nothing from this message was kept; the owner is being told to send it again."
            )
            return Outcome(refusals: attachments.map {
                Refusal(
                    name: Self.ownerFacingName(for: $0),
                    contentType: $0.contentType,
                    isImage: $0.isImage,
                    reason: "the attachments directory \(directory.path) could not be created: \(error)"
                )
            })
        }

        var kept: [Kept] = []
        var refusals: [Refusal] = []
        for attachment in attachments {
            guard let source = attachment.localURL else {
                // signal-cli reported it but has not written it yet, or wrote it
                // where we did not look. Said out loud *to the owner*, because
                // they are about to be told what was kept and this one was not.
                log(
                    "[attachments] \(attachment.contentType ?? "unknown") has no file on disk yet;"
                        + " the owner is being told to send it again"
                )
                refusals.append(
                    Refusal(
                        name: Self.ownerFacingName(for: attachment),
                        contentType: attachment.contentType,
                        isImage: attachment.isImage,
                        reason: "the channel reported it but no file had been written to disk"
                    )
                )
                continue
            }
            switch keepOne(
                source,
                attachment: attachment,
                via: channel,
                caption: caption,
                receivedAt: receivedAt,
                in: directory,
                log: log
            ) {
            case .kept(let one): kept.append(one)
            case .refused(let refusal): refusals.append(refusal)
            }
        }
        return Outcome(kept: kept, refusals: refusals)
    }

    /// One attachment's verdict. Deliberately not `Result`, because a
    /// `Refusal` is not an `Error`: nothing throws it, and making it throwable
    /// would invite exactly the `try?` that lost these files in the first place.
    private enum Filed {
        case kept(Kept)
        case refused(Refusal)
    }

    private func keepOne(
        _ source: URL,
        attachment: ChannelAttachment,
        via channel: ChannelKind,
        caption: String?,
        receivedAt: Date,
        in directory: URL,
        log: (String) -> Void
    ) -> Filed {
        let name = Self.fileName(for: attachment, caption: caption, receivedAt: receivedAt)
        let destination = directory.appendingPathComponent(name, isDirectory: false)
        let spoken = Self.ownerFacingName(for: attachment, source: source)

        let bytes: Data
        do {
            bytes = try Data(contentsOf: source)
            try OwnerOnlyFileSecurity.write(bytes, to: destination, fileManager: fileManager)
        } catch {
            log(
                "[attachments] could not keep \(source.lastPathComponent): \(error)."
                    + " The owner is being told it did not save and asked to send it again."
            )
            return .refused(
                Refusal(
                    name: spoken,
                    contentType: attachment.contentType,
                    isImage: attachment.isImage,
                    reason: "\(source.path) could not be copied to \(destination.path): \(error)"
                )
            )
        }

        do {
            let note = try writeNote(
                for: destination,
                attachment: attachment,
                via: channel,
                caption: caption,
                receivedAt: receivedAt
            )
            log("[attachments] kept \(destination.lastPathComponent) (\(bytes.count) bytes) and noted it")
            return .kept(Kept(file: destination, note: note, caption: caption, isImage: attachment.isImage))
        } catch {
            // **The bytes are kept and the file is not findable**, which is a
            // third state and has to be reported as a loss rather than as a
            // success. `notes_list` and every search path go through the note,
            // so a file with no note beside it can never be asked for by name —
            // from the owner's chair it is gone. The bytes stay where they are
            // rather than being deleted: a copy they cannot search for is still
            // better than a copy that no longer exists, and the log says where.
            log(
                "[attachments] kept \(destination.lastPathComponent) but could not write the note"
                    + " beside it: \(error). Without the note it cannot be searched for or sent back,"
                    + " so the owner is being told it did not save. The bytes are at \(destination.path)."
            )
            return .refused(
                Refusal(
                    name: spoken,
                    contentType: attachment.contentType,
                    isImage: attachment.isImage,
                    reason: "the bytes reached \(destination.path) but the note that makes it"
                        + " searchable could not be written: \(error)"
                )
            )
        }
    }

    /// The note is the searchable half.
    ///
    /// A `.png` in a folder is not findable by meaning — SAGE indexes what the
    /// owner *said*, and `notes_read` returns text. So the caption, the date and
    /// the path go in a note, and asking for "the ferry booking" finds the note,
    /// which names the file.
    private func writeNote(
        for file: URL,
        attachment: ChannelAttachment,
        via channel: ChannelKind,
        caption: String?,
        receivedAt: Date
    ) throws -> URL {
        let slug = NoteSlug.slug(from: Self.title(caption: caption, receivedAt: receivedAt))
        let note = notesDirectory.appendingPathComponent(slug + ".md", isDirectory: false)

        var lines = [
            "# \(Self.title(caption: caption, receivedAt: receivedAt))",
            "",
            "Sent to Mynah on \(channel.displayName), \(Self.stamp(receivedAt, style: Self.noteDateStyle))."
        ]
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["", "What you said when you sent it:", "", "> \(caption)"]
        }
        lines += [
            "",
            "The file is kept at `\(Self.subdirectory)/\(file.lastPathComponent)`"
                + " (\(attachment.contentType ?? "unknown type"))."
        ]

        try OwnerOnlyFileSecurity.write(Data(lines.joined(separator: "\n").utf8), to: note, fileManager: fileManager)
        return note
    }

    // MARK: - Dates

    /// The style the note's date line has always used.
    static var noteDateStyle: Date.FormatStyle { Date.FormatStyle(date: .long, time: .shortened) }

    /// The style a captionless title has always used. Shorter, because it ends
    /// up in a filename.
    static var titleDateStyle: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .shortened) }

    /// **`Date.FormatStyle` is the right answer on both platforms, and the
    /// obvious replacement for it is a macOS regression.**
    ///
    /// This is extracted rather than written inline so a test can pin it,
    /// because it is the first thing anyone reaches for when Linux drops an
    /// attachment — `formatted(date:time:)` is the one exotic-looking call in
    /// the path, and swift-corelibs-Foundation has a reputation. Two
    /// measurements say it is innocent, both worth keeping:
    ///
    /// 1. **It cannot be what threw.** `Date.formatted(_:)` is not a throwing
    ///    function. The `catch` that was swallowing every Linux attachment can
    ///    only have caught `Data(contentsOf:)` or `OwnerOnlyFileSecurity.write`,
    ///    and it was the second.
    /// 2. **It works, and it agrees with itself across platforms.** For a
    ///    pinned locale and time zone, swift:6.0-jammy and macOS 15 produce
    ///    byte-identical output, narrow no-break space and all —
    ///    `August 7, 2025 at 4:00\u{202F}PM` on both.
    ///
    /// The tempting swap — `DateFormatter` with `dateStyle`/`timeStyle` — is
    /// *not* equivalent and would quietly change what macOS owners have been
    /// reading since 1.0. Measured over twenty locales, the two disagree in
    /// thirteen: `de_DE` abbreviated becomes `08.08.2025` instead of
    /// `8. Aug. 2025`, `ja_JP` becomes `2025/08/08` instead of `2025年8月8日`,
    /// and `th_TH` switches to the Buddhist calendar and prints the year as
    /// **2568**. Those strings are not decoration — a captionless title becomes
    /// a filename through `NoteSlug.slug`, so changing them renames files the
    /// owner already has. `SignalAttachmentStoreDateStampTests` fails if anyone
    /// makes that swap.
    static func stamp(_ date: Date, style: Date.FormatStyle) -> String {
        date.formatted(style)
    }

    // MARK: - Names

    /// A name that says what it is, with a hash so two photos sent in the same
    /// minute cannot land on each other.
    static func fileName(for attachment: ChannelAttachment, caption: String?, receivedAt: Date) -> String {
        let stem = NoteSlug.slug(from: title(caption: caption, receivedAt: receivedAt))
        let unique = SHA256.hash(data: Data((attachment.id + attachment.contentType.orEmpty).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(6)
        return "\(stem)-\(unique).\(Self.fileExtension(for: attachment))"
    }

    private static func fileExtension(for attachment: SignalAttachment) -> String {
        attachment.localURL.map { $0.pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
            ?? SignalAttachmentLocator.fileExtension(forMIMEType: attachment.contentType ?? "")
            ?? "bin"
    }

    /// What to call a file the owner is being asked to send again.
    ///
    /// Their phone's name for it first, because that is the one on their screen.
    /// The name on disk second — signal-cli writes decrypted attachments under
    /// their own ids, so this is a last resort and not a good one. Then the
    /// content type, which at least distinguishes the PDF from the photo. Never
    /// nothing: an unnamed refusal is barely better than the silence it
    /// replaced.
    static func ownerFacingName(for attachment: ChannelAttachment, source: URL? = nil) -> String {
        let candidates = [
            attachment.filename,
            (source ?? attachment.localURL)?.lastPathComponent,
            attachment.contentType.map { "the \($0) they sent" }
        ]
        for candidate in candidates {
            let trimmed = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return attachment.isImage ? "the photo they sent" : "the file they sent"
    }

    /// The caption when there is one, because that is what the owner will search
    /// for. A date otherwise — never "attachment", which is a word that
    /// distinguishes nothing when there are forty of them.
    static func title(caption: String?, receivedAt: Date) -> String {
        let trimmed = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Attachment from \(stamp(receivedAt, style: titleDateStyle))"
        }
        return String(trimmed.prefix(80))
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
