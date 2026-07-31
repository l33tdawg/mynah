import Foundation

/// What a SAGE domain is called on screen.
///
/// The node names an agent's default home domain after the agent itself:
/// `local-` followed by the 64 hex characters of its public key. That is a
/// perfectly good key and a terrible label. On the task board and in the
/// memory cards it rendered as
///
///     local-1ab7aa106b3580b5ad01042038bb9094c2adf8…
///
/// truncated mid-hash, in a chip beside "Book hotel for Wednesday 19th" — where
/// its only job is to tell the owner *which pile this went in*. It answered a
/// question nobody asked and hid the one they did.
///
/// The owner's words for the fix: *"'local agent domain' should show a nicer
/// name like 'mynah-personal-domain' in the card instead of this"*.
///
/// ## Why not "mynah-personal-domain" exactly
///
/// Owner-facing strings in this product say **subject**, never "domain" — SAGE's
/// word is domain and the code may use it, but the screens may not, and there
/// are tests that enforce it. "Mynah's own" says the same thing in the product's
/// own vocabulary and reads as a phrase rather than an identifier.
public enum MemorySubjectName {

    /// The appliance's own home subject.
    public static let ownHome = "Mynah's own"

    /// The node's prefix for an agent's default home domain.
    private static let localPrefix = "local-"

    /// A label for `raw`, which may be any domain the node hands back.
    ///
    /// - Parameter applianceAgentID: Mynah's own id. Passed in rather than read
    ///   here so this stays a pure function — the same string must produce the
    ///   same label in a test as on the owner's Mac, and a helper that reaches
    ///   for a key file cannot promise that.
    public static func display(_ raw: String, applianceAgentID: String?) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased().hasPrefix(localPrefix) else { return name }

        let id = String(name.dropFirst(localPrefix.count))
        if let applianceAgentID, !applianceAgentID.isEmpty,
           id.compare(applianceAgentID, options: .caseInsensitive) == .orderedSame {
            return ownHome
        }

        // Somebody else's home subject. Shortened rather than renamed: this is
        // still an agent the owner may not recognise, and inventing a friendly
        // name for a stranger would be worse than a short true one. Only when
        // it really is a key — an arbitrary domain that happens to start with
        // "local-" is a name its author chose and is left alone.
        guard id.count >= 32, id.allSatisfy(\.isHexDigit) else { return name }
        return "\(localPrefix)\(id.prefix(8))…"
    }

    /// Whether `raw` is the appliance's own home subject.
    ///
    /// Separate from `display` because callers that want to *style* the chip
    /// differently should not be matching on a display string — that couples
    /// the look to the wording, and the wording is the part that changes.
    public static func isOwnHome(_ raw: String, applianceAgentID: String?) -> Bool {
        display(raw, applianceAgentID: applianceAgentID) == ownHome
    }
}
