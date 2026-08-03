import Foundation

/// Finds a file the owner already has, by the words they call it.
///
/// ## The gap this fills
///
/// Everything needed to hand a file back was already here except the last step.
/// `SignalAttachmentStore` keeps what the owner sends and writes a note beside
/// it; `NotesToolSource` writes documents and exports them; the daemon attaches
/// files to a reply and the window shows them as something to click. But the
/// only files that could ever ride out were the ones written **during that
/// turn** — `drainOutgoingFiles` returns what this turn produced.
///
/// So "send me that ferry ticket again" had no path at all. Mynah could find the
/// note describing it, read the note aloud, and name the file — and then had no
/// way to give the owner the file, which is the only thing they asked for.
///
/// ## Two steps, because the owner asked for two
///
/// > maybe do it in 2 steps - look it up; then send - this way we don't burn the
/// > context window in 1 go.
///
/// The looking up is `list_notes` and `read_note`, which already exist and
/// already see attachment notes — the store writes them into the notes root for
/// exactly this reason. This type is only the second step, so the catalogue
/// grows by one tool rather than two, which matters: routing accuracy fell off
/// measurably past ~14 tools (see `BrainPrompts.voiceToolAllowlist`).
///
/// ## Why a title and never a path
///
/// The same argument as `NotesToolSource`, and it has to be stronger here
/// because sending is *outbound*. A path taken from the model is a path someone
/// else may have chosen: instructions reaching this tool have passed through
/// speech recognition and through `web_search` results written by strangers, and
/// a traversal here does not corrupt a note — it mails the owner's private file
/// to whoever is in the thread.
///
/// So nothing is ever parsed into a path. A title becomes a slug through
/// `NoteSlug.slug(from:)` — an allowlist of alphanumerics, so `..` and `/` are
/// not representable — and that slug is then *matched against a real directory
/// listing*. The only files this type can name are files it just saw on disk in
/// one of three known directories.
///
/// **In particular, the note's own text is never read for a filename.** A note
/// says `The file is kept at ​`attachments/x.png`​`, which is tempting and wrong:
/// note bodies are model-written, so a note could just as easily claim the file
/// is kept at `attachments/../../../.ssh/id_rsa`. The attachment is found by
/// listing `attachments/` instead, which cannot be talked into containing
/// something that is not there.
struct StoredFiles {

    /// Files sent for one title before it stops. A caption on a batch of photos
    /// is shared by all of them, so this is reached by ordinary use rather than
    /// only by abuse — and forty photos on one reply is not a thing anybody
    /// wanted.
    static let maximumFilesPerSend = 10

    /// Slugs named in a "did you mean" line.
    static let maximumSuggestions = 20

    /// The hex `SignalAttachmentStore.fileName` appends so two photos sent in the
    /// same minute cannot land on each other. Knowing its exact length is what
    /// makes the slug recoverable from the filename without guessing where the
    /// hyphens stop being part of the title.
    static let attachmentHashLength = 6

    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// One thing the owner can be handed, and every file that makes it up.
    struct Match: Equatable {
        /// The slug it was filed under.
        let slug: String
        /// What to call it out loud.
        let title: String
        /// What to send, in the order it should go. More than one when the owner
        /// sent several photos under a single caption.
        let files: [URL]
    }

    /// What asking for a title got.
    ///
    /// `several` is a deliberate non-answer. The alternative — send everything
    /// that looked close — is the shape of the bug that piped the owner's
    /// messages to strangers: a substring matched two unrelated things and the
    /// model picked. Naming the candidates costs a turn; guessing costs a file
    /// going somewhere it should not.
    enum Resolution: Equatable {
        case nothing(available: [String])
        case one(Match)
        case several([String])
    }

    // MARK: - Looking

    func match(title: String) -> Resolution {
        let asked = NoteSlug.slug(from: title)
        let catalogue = catalogue()
        guard !catalogue.isEmpty else { return .nothing(available: []) }

        let slugs = catalogue.keys.sorted()
        let hits = Self.slugs(matching: asked, among: slugs)

        switch hits.count {
        case 0:
            return .nothing(available: slugs.prefix(Self.maximumSuggestions).map(Self.readable))
        case 1:
            let slug = hits[0]
            return .one(Match(
                slug: slug,
                title: Self.readable(slug),
                files: Array((catalogue[slug] ?? []).prefix(Self.maximumFilesPerSend))
            ))
        default:
            return .several(hits.prefix(Self.maximumSuggestions).map(Self.readable))
        }
    }

    /// Slug matching, loosest rule that still finds something.
    ///
    /// Exact equality alone is not enough in practice and the reason is in how
    /// attachment notes are titled: the slug comes from the owner's *caption*,
    /// so the ferry ticket is filed as `ferry-ticket-to-betong-on-the-14th` and
    /// asked for as "the ferry ticket". Requiring an exact match means the owner
    /// has to quote their own caption back word for word, which nobody does.
    ///
    /// The rules widen only until one of them finds something, so a title that
    /// matches exactly never has to compete with one that merely shares a word.
    static func slugs(matching asked: String, among candidates: [String]) -> [String] {
        guard !asked.isEmpty else { return [] }

        // 1. The same thing, said the same way. Before any loosening, so a title
        //    that matches exactly never competes with one that merely shares a
        //    word — and so a note genuinely called "the it list" still matches
        //    itself after the stripping below.
        let exact = candidates.filter { $0 == asked }
        if !exact.isEmpty { return exact }

        let askedWords = withoutGrammarWords(words(asked))
        guard !askedWords.isEmpty else { return [] }

        // 2. One is a run of words inside the other. Covers "ferry ticket" for
        //    `ferry-ticket-to-betong`, and a model quoting a listed title back
        //    with a word of its own added.
        let contained = candidates.filter {
            let candidateWords = words($0)
            return containsRun(candidateWords, askedWords) || containsRun(askedWords, candidateWords)
        }
        if !contained.isEmpty { return contained }

        // 3. Every word asked for is in there somewhere, in any order. Covers
        //    "betong ferry" — how somebody remembers a thing is not the order
        //    they wrote it down in.
        let scattered = candidates.filter { candidate in
            let candidateWords = Set(words(candidate))
            return askedWords.allSatisfy(candidateWords.contains)
        }
        if !scattered.isEmpty { return scattered }

        // 4. The same, ignoring what *kind* of thing they said it was. "my hugo
        //    boss note" is one word away from matching, and the extra word is
        //    the owner describing the file rather than naming it — nothing is
        //    ever filed as "the hugo boss note", because the title came from
        //    their caption.
        //
        //    Last, so it can never outrank a title that really does contain the
        //    word: somebody with a note called "voice note" is asking for that
        //    one, not for everything with "voice" in it.
        let named = askedWords.filter { !kindWords.contains($0) }
        guard !named.isEmpty, named.count < askedWords.count else { return [] }
        return candidates.filter { candidate in
            let candidateWords = Set(words(candidate))
            return named.allSatisfy(candidateWords.contains)
        }
    }

    private static func words(_ slug: String) -> [String] {
        slug.split(separator: "-").map(String.init)
    }

    /// Words that carry grammar rather than meaning.
    ///
    /// **Dropped from what was asked for, never from what is stored.** A title
    /// is whatever the owner captioned it, and their captions are sentences —
    /// `here-s-the-ferry-booking-please-store-it` is a real one. Stripping both
    /// sides would let "please store" match it, which is matching on the filler.
    /// Stripping only the request lets "the thailand bookings" find
    /// `thailand-trip-bookings`, which is the thing somebody actually says.
    private static let grammarWords: Set<String> = [
        "a", "an", "the", "my", "our", "your", "its",
        "this", "that", "these", "those", "it", "them",
        "and", "or", "of", "for", "to", "from", "on", "in", "at", "with",
        "me", "i", "please", "again"
    ]

    /// Empty when the request was nothing but grammar, which is the correct
    /// answer rather than a degenerate one: "please" names no file, and matching
    /// it against a caption that happens to end "…please store it" is matching
    /// on the filler.
    ///
    /// Nothing is lost by refusing. A note genuinely titled "it" is found by
    /// rule 1, which runs before any of this.
    private static func withoutGrammarWords(_ words: [String]) -> [String] {
        words.filter { !grammarWords.contains($0) }
    }

    /// What kind of thing it is, which the owner says and the filename does not
    /// contain — titles come from captions, and nobody captions a photo "photo".
    /// Only consulted after every stricter rule has failed.
    private static let kindWords: Set<String> = [
        "note", "notes", "document", "doc", "file", "files", "copy", "attachment",
        "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images",
        "pdf", "scan", "screenshot"
    ]

    /// Whether `needle` appears in `haystack` as consecutive words.
    ///
    /// Word-wise rather than substring, so "art" does not match "cartier" — the
    /// class of near-miss that makes a fuzzy matcher dangerous rather than
    /// merely imprecise.
    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start ..< start + needle.count]) == needle {
            return true
        }
        return false
    }

    static func readable(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - What is on disk

    /// Every slug that can be sent, and the files to send for it.
    ///
    /// Preference order within a slug, and each step is a judgement about what
    /// the owner meant:
    ///
    /// 1. **Attachments.** What they sent is what they are asking for back. The
    ///    note beside it is an index card, not the thing.
    /// 2. **The newest export.** Asking for a document they had made as a PDF
    ///    means the PDF, not the markdown it was rendered from.
    /// 3. **The note.** Nothing else exists, and the markdown is still a real
    ///    file they can open.
    func catalogue() -> [String: [URL]] {
        let attachments = grouped(
            in: directory.appendingPathComponent(SignalAttachmentStore.subdirectory, isDirectory: true),
            slug: Self.attachmentSlug(fromFileName:)
        )
        let documents = grouped(
            in: directory.appendingPathComponent("documents", isDirectory: true),
            slug: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        )
        let notes = grouped(in: directory, slug: { name in
            guard name.lowercased().hasSuffix(".md") else { return nil }
            return String(name.dropLast(3))
        })

        var catalogue: [String: [URL]] = [:]
        for slug in Set(attachments.keys).union(documents.keys).union(notes.keys) {
            if let kept = attachments[slug], !kept.isEmpty {
                catalogue[slug] = kept.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else if let exported = documents[slug], !exported.isEmpty {
                // One, not all: a note exported twice — once as a deck for a
                // meeting, once as a PDF to read — should not send both because
                // somebody asked for "the quarterly brief".
                catalogue[slug] = [newest(of: exported)]
            } else if let note = notes[slug]?.first {
                catalogue[slug] = [note]
            }
        }
        return catalogue
    }

    /// The slug an attachment was filed under, or `nil` if this is not one of
    /// ours.
    ///
    /// `SignalAttachmentStore` names them `<slug>-<6 hex>.<ext>`, so the slug is
    /// everything before the last seven characters of the stem — provided those
    /// seven really are a hyphen and six hex digits. Checking rather than
    /// assuming keeps a file somebody dropped into the folder by hand from being
    /// filed under a slug with its last word chopped off.
    static func attachmentSlug(fromFileName name: String) -> String? {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        guard stem.count > attachmentHashLength + 1 else { return nil }
        let hash = stem.suffix(attachmentHashLength)
        let separator = stem.dropLast(attachmentHashLength).last
        guard separator == "-",
              hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return String(stem.dropLast(attachmentHashLength + 1))
    }

    private func grouped(in folder: URL, slug: (String) -> String?) -> [String: [URL]] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [:] }

        var grouped: [String: [URL]] = [:]
        for file in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: file.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let slug = slug(file.lastPathComponent),
                  !slug.isEmpty else { continue }
            grouped[slug, default: []].append(file)
        }
        return grouped
    }

    /// Newest by modification date, name as the tie-break so two files written
    /// in the same second do not reorder themselves between calls.
    private func newest(of files: [URL]) -> URL {
        files.max { left, right in
            let a = modified(left), b = modified(right)
            return a == b ? left.lastPathComponent > right.lastPathComponent : a < b
        } ?? files[0]
    }

    private func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    func sizeInBytes(of file: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
    }
}
