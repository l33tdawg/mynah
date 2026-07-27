import Foundation

/// Finds the decrypted bytes of a received attachment on disk.
///
/// signal-cli reports only attachment metadata over JSON-RPC (`JsonAttachment` is
/// `contentType, filename, id, size, width, height, caption, uploadTimestamp` — there is
/// no path field). The file itself is written by `AttachmentStore`:
///
///     new File(attachmentsPath, sanitizeId(remoteId) + extension)
///     sanitizeId(id)  = id.replaceAll("[^A-Za-z0-9_.-]", "_")
///     extension       = "." + (filename extension ?: guessed from the MIME type), else ""
///
/// Because the extension is *guessed*, a voice note (`audio/aac`, no filename) may land as
/// `<id>.aac` or as plain `<id>` depending on the MIME table of the running signal-cli.
/// So: try the computed names, then fall back to scanning for `<id>*`.
public enum SignalAttachmentLocator {
    /// `$XDG_DATA_HOME/signal-cli/attachments`, defaulting to `~/.local/share/signal-cli/attachments`.
    /// Pass `dataDirectory` when the daemon runs with `--data-dir`.
    public static func defaultAttachmentsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        let base: String
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            base = xdg
        } else {
            base = "\(homeDirectory)/.local/share"
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("signal-cli", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
    }

    public static func attachmentsDirectory(forDataDirectory dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    public static let audioFileExtensions: Set<String> = [
        "aac", "m4a", "mp3", "mp4a", "ogg", "oga", "opus", "wav", "wave",
        "flac", "amr", "3gp", "3gpp", "caf", "aiff", "aif", "weba"
    ]

    /// Mirrors `AttachmentStore.sanitizeId`.
    public static func sanitize(_ id: String) -> String {
        var out = ""
        out.reserveCapacity(id.count)
        for character in id {
            if character.isASCII, character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                out.append(character)
            } else {
                out.append("_")
            }
        }
        return out
    }

    /// Best-effort mirror of signal-cli's `MimeUtils.guessExtensionFromMimeType` for the
    /// types that actually turn up on a voice-note path. Only used to *guess* a candidate
    /// filename; the directory scan is the real safety net.
    public static func fileExtension(forMIMEType mimeType: String) -> String? {
        let normalized = mimeType.lowercased().split(separator: ";").first.map(String.init) ?? mimeType.lowercased()
        switch normalized.trimmingCharacters(in: .whitespaces) {
        case "audio/aac", "audio/x-aac", "audio/aacp": return "aac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/mpeg", "audio/mp3", "audio/x-mpeg": return "mp3"
        case "audio/ogg", "application/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": return "wav"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/amr", "audio/3gpp": return "amr"
        case "audio/webm", "video/webm": return "webm"
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        default: return nil
        }
    }

    static func fileExtension(forFilename filename: String) -> String? {
        guard let dot = filename.lastIndex(of: "."), dot != filename.index(before: filename.endIndex) else {
            return nil
        }
        return String(filename[filename.index(after: dot)...])
    }

    /// Candidate file names, most specific first. Exposed for tests.
    public static func candidateFileNames(id: String, filename: String?, contentType: String?) -> [String] {
        let safe = sanitize(id)
        var names: [String] = []
        if let filename, let ext = fileExtension(forFilename: filename) {
            names.append("\(safe).\(ext)")
        }
        if let contentType, let ext = fileExtension(forMIMEType: contentType) {
            names.append("\(safe).\(ext)")
        }
        names.append(safe)
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    /// Resolves the on-disk file, or `nil` if signal-cli did not download it
    /// (`--ignore-attachments`) or it has already been cleaned up.
    public static func locate(
        id: String,
        filename: String? = nil,
        contentType: String? = nil,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard !id.isEmpty else {
            return nil
        }
        for name in candidateFileNames(id: id, filename: filename, contentType: contentType) {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // Extension guessing can disagree with the running signal-cli build; fall back to
        // "any file whose name is the sanitised id plus an extension", ignoring previews.
        let safe = sanitize(id)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let matches = entries
            .filter { $0 == safe || $0.hasPrefix("\(safe).") }
            .filter { !$0.hasSuffix(".preview") }
            .sorted()
        guard let match = matches.first else {
            return nil
        }
        return directory.appendingPathComponent(match, isDirectory: false)
    }
}
