import Foundation

/// One file the appliance has kept, as a screen needs to show it.
public struct SavedFile: Identifiable, Sendable, Hashable {

    /// Which of the three places it came from.
    ///
    /// Shown to the owner because the answer to "can I delete this?" is
    /// different for each: a note is something Mynah wrote and can write again,
    /// a document is a conversion of one, and an attachment is a file the owner
    /// themselves sent and may have no other copy of.
    public enum Kind: String, Sendable, Hashable {
        case note
        case document
        case attachment

        /// In the owner's words, not the directory's.
        public var word: String {
            switch self {
            case .note: return "Note"
            case .document: return "Document"
            case .attachment: return "Received"
            }
        }
    }

    public var id: String { path }

    /// The resolved path, which is also the identity — see `SavedFilesStore.remove`.
    public let path: String
    public let name: String
    public let kind: Kind
    public let bytes: Int64
    public let saved: Date

    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, name: String, kind: Kind, bytes: Int64, saved: Date) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.saved = saved
    }

    /// Rounded the way a person reads a file size.
    ///
    /// **`.useBytes` is in the list because leaving it out reads as a bug.**
    /// Without it `ByteCountFormatter` rounds anything under half a kilobyte to
    /// "0 KB", and the owner saw exactly that: a 274-byte note beside a photo,
    /// displayed as `0 KB`, which he read as an empty file being written. The
    /// note was fine; the label was lying about it.
    ///
    /// Companion notes are routinely this small — a title, a date and the path
    /// of the attachment — so the size the screen is worst at is the size it
    /// shows most often.
    public var readableSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// Everything the appliance has written down or been sent, and the only way to
/// remove any of it.
///
/// ## Why this exists
///
/// Three directories accumulate files for the life of the appliance and nothing
/// has ever listed them. `write_note` writes markdown into the notes root,
/// documents are converted beside them, and `SignalAttachmentStore` keeps every
/// photo and PDF the owner has ever sent. The owner: *"we can't view or remove
/// files - should be in this what mynah remembers section"*, and before that
/// *"there's no way to clean that up"*.
///
/// Both halves were true. The model could list notes, but nothing could show the
/// owner a photo from four months ago, and nothing at all could delete one.
///
/// ## Removal is confined by construction
///
/// The same argument `StoredFiles` makes about sending, and it has to be at
/// least as strong here because this deletes. Nothing is ever built from a path
/// handed in: `remove` takes a `SavedFile`, resolves it, and refuses unless the
/// resolved path is inside one of the three directories this store just listed.
///
/// Resolved on both sides before comparing, because on macOS the notes root is
/// reachable as both `/var/…` and `/private/var/…` — the same trap
/// `NotesToolSource.deliver` documents, where an unresolved `==` saw two
/// different files and sent the owner their document twice. Here the same
/// mistake would refuse a legitimate delete, which the owner would read as the
/// button not working.
public struct SavedFilesStore: Sendable {

    private let notesDirectory: URL
    private let fileManager: FileManager

    public init(
        notesDirectory: URL = NotesToolSource.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.notesDirectory = notesDirectory
        self.fileManager = fileManager
    }

    /// The three places, and what a file found in each one is.
    ///
    /// The notes root is listed shallowly and filtered to markdown on purpose:
    /// `documents` and `attachments` are inside it, and a deep enumeration would
    /// list every file three times under the wrong kind.
    private var places: [(url: URL, kind: SavedFile.Kind, onlyMarkdown: Bool)] {
        [
            (notesDirectory, .note, true),
            (notesDirectory.appendingPathComponent("documents", isDirectory: true), .document, false),
            (notesDirectory.appendingPathComponent("attachments", isDirectory: true), .attachment, false),
        ]
    }

    /// Newest first, which is the order somebody looking for what they just sent
    /// wants.
    public func all() -> [SavedFile] {
        var found: [SavedFile] = []
        for place in places {
            let contents = (try? fileManager.contentsOfDirectory(
                at: place.url,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for file in contents {
                let values = try? file.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
                )
                if values?.isDirectory == true { continue }
                if place.onlyMarkdown, file.pathExtension.lowercased() != "md" { continue }

                found.append(SavedFile(
                    path: file.resolvingSymlinksInPath().standardizedFileURL.path,
                    name: file.lastPathComponent,
                    kind: place.kind,
                    bytes: Int64(values?.fileSize ?? 0),
                    saved: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                ))
            }
        }
        return found.sorted { $0.saved > $1.saved }
    }

    public enum Trouble: Error, Equatable {
        /// The path is not inside any directory this store owns. Never reached
        /// by the screen; reached by anything that built a `SavedFile` itself.
        case notOurs(String)
        case couldNotRemove(String)
    }

    /// Deletes one file, and only if it is genuinely one of ours.
    public func remove(_ file: SavedFile) throws {
        let target = URL(fileURLWithPath: file.path)
            .resolvingSymlinksInPath().standardizedFileURL

        let allowed = places.map {
            $0.url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        // The *parent* must be one of the three, not merely a prefix of the
        // path. A prefix check would accept `…/Notes/attachments/../../.ssh/id_rsa`
        // before resolution and anything nested after it.
        guard allowed.contains(target.deletingLastPathComponent().path) else {
            throw Trouble.notOurs(file.path)
        }

        do {
            try fileManager.removeItem(at: target)
        } catch {
            throw Trouble.couldNotRemove("\(error)")
        }
    }
}
