import CryptoKit
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
    }

    /// Copies each attachment in and writes one note describing it.
    ///
    /// Never throws. A photo that cannot be copied is worth a log line and a
    /// turn that carries on — refusing to answer because one attachment was
    /// unreadable would be a worse appliance than one that says what it kept.
    @discardableResult
    public func keep(
        _ attachments: [SignalAttachment],
        caption: String?,
        receivedAt: Date,
        log: (String) -> Void = { _ in }
    ) -> [Kept] {
        guard !attachments.isEmpty else { return [] }

        let directory = notesDirectory.appendingPathComponent(Self.subdirectory, isDirectory: true)
        do {
            try OwnerOnlyFileSecurity.prepareDirectory(directory)
        } catch {
            log("[attachments] could not prepare \(directory.path): \(error)")
            return []
        }

        return attachments.compactMap { attachment in
            guard let source = attachment.localURL else {
                // signal-cli reported it but has not written it yet, or wrote it
                // where we did not look. Said out loud, because the owner is
                // about to be told what was kept and this one was not.
                log("[attachments] \(attachment.contentType ?? "unknown") has no file on disk yet")
                return nil
            }
            return keep(source, attachment: attachment, caption: caption, receivedAt: receivedAt, in: directory, log: log)
        }
    }

    private func keep(
        _ source: URL,
        attachment: SignalAttachment,
        caption: String?,
        receivedAt: Date,
        in directory: URL,
        log: (String) -> Void
    ) -> Kept? {
        let name = Self.fileName(for: attachment, caption: caption, receivedAt: receivedAt)
        let destination = directory.appendingPathComponent(name, isDirectory: false)

        do {
            let bytes = try Data(contentsOf: source)
            try OwnerOnlyFileSecurity.write(bytes, to: destination, fileManager: fileManager)

            let note = try writeNote(
                for: destination,
                attachment: attachment,
                caption: caption,
                receivedAt: receivedAt
            )
            log("[attachments] kept \(destination.lastPathComponent) (\(bytes.count) bytes) and noted it")
            return Kept(file: destination, note: note, caption: caption)
        } catch {
            log("[attachments] could not keep \(source.lastPathComponent): \(error)")
            return nil
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
        attachment: SignalAttachment,
        caption: String?,
        receivedAt: Date
    ) throws -> URL {
        let slug = NoteSlug.slug(from: Self.title(caption: caption, receivedAt: receivedAt))
        let note = notesDirectory.appendingPathComponent(slug + ".md", isDirectory: false)

        let stamp = receivedAt.formatted(date: .long, time: .shortened)
        var lines = [
            "# \(Self.title(caption: caption, receivedAt: receivedAt))",
            "",
            "Sent to Mynah on Signal, \(stamp)."
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

    /// A name that says what it is, with a hash so two photos sent in the same
    /// minute cannot land on each other.
    static func fileName(for attachment: SignalAttachment, caption: String?, receivedAt: Date) -> String {
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

    /// The caption when there is one, because that is what the owner will search
    /// for. A date otherwise — never "attachment", which is a word that
    /// distinguishes nothing when there are forty of them.
    static func title(caption: String?, receivedAt: Date) -> String {
        let trimmed = (caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Attachment from \(receivedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return String(trimmed.prefix(80))
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
