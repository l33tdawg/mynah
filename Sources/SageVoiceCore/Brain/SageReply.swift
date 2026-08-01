import Foundation

/// Reading an answer out of what the node actually says.
///
/// **The node appends prose to tool results, and it does not always.** A reply
/// looks like this when SAGE decides the caller is overdue a `sage_turn`:
///
///     {
///       "total_open": 3
///     }
///
///     [SAGE] Reminder: call sage_turn with the current topic + observation.
///
/// `JSONSerialization` refuses trailing bytes, so `jsonObject(with:)` on the
/// whole string returns nil — and every reader in this product treated nil as
/// *empty*, because an empty inbox and an unreadable one look the same to a
/// screen with nothing to show. So the appliance reported no tasks and no
/// waiting messages while the node was answering with three tasks, and did it
/// **intermittently**, because the reminder only appears every few calls.
///
/// Measured on 2 August: `sage_backlog` returned 1,709 characters of which the
/// last 121 were the reminder. `sage-voiced check` said "0 open" against a node
/// whose own words in the same breath were "You have 3 assigned open tasks".
///
/// So the object is found rather than assumed: from the first `{` to the brace
/// that closes it, counting depth and ignoring anything inside a string. Not
/// "first `{` to last `}`" — the appended prose is free text and a `}` in it
/// would swallow the lot.
///
/// **The app worked this out first and this is its logic, moved.**
/// `SageMemoryStore.embeddedObject` has done exactly this since the Memories
/// page was built, which is why the task board reads a backlog correctly and
/// why everything in this module — the agent inbox, the dictation vocabulary,
/// the proactive check — did not. One implementation, in the module both sides
/// can see, rather than a fix that only exists where somebody happened to hit
/// the bug.
public enum SageReply {

    /// The banner the node puts *before* the payload on the first call of a
    /// session, ending in a horizontal rule of its own.
    static let bannerRule = "\n\n---\n\n"

    /// The first complete JSON object in whatever the node said.
    public static func object(in reply: String) -> [String: Any]? {
        guard let slice = jsonSlice(in: reply),
              let data = slice.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root
    }

    /// The substring holding the first balanced `{…}`.
    ///
    /// Written out rather than done with a regular expression because nesting
    /// is the whole problem — `tasks_by_domain` is objects inside objects — and
    /// a regex that handles balanced braces is either wrong or unreadable.
    static func jsonSlice(in text: String) -> String? {
        // The banner is cut before the brace matcher runs, so a banner that
        // ever grows a brace of its own cannot capture it. Backwards, because
        // the payload can legitimately contain the same sequence inside a
        // string and the *last* rule is the one that ends the banner.
        var reply = text
        if let rule = reply.range(of: bannerRule, options: .backwards) {
            reply = String(reply[rule.upperBound...])
        }
        guard let start = reply.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < reply.endIndex {
            let character = reply[index]
            if escaped {
                // The character after a backslash is data, whatever it is.
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(reply[start...index])
                    }
                }
            }
            index = reply.index(after: index)
        }
        // Ran out before the object closed: a truncated answer, which is not
        // something to guess at.
        return nil
    }
}

public extension SageReply {

    /// The same reading, as the value type the rest of this product passes
    /// around.
    static func value(in reply: String) -> JSONValue? {
        // The whole string first, because a well-formed answer is the common
        // case and this keeps it a single parse.
        if let whole = JSONValue.parse(reply), whole.objectValue != nil { return whole }
        guard let slice = jsonSlice(in: reply) else { return nil }
        return JSONValue.parse(slice)
    }
}
