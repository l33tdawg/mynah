import Foundation

/// What the appliance says while the owner is still waiting.
///
/// A local turn that calls tools takes 20–50 seconds, and silence for that long
/// reads as broken — the owner has twice reported a working appliance as hung.
/// Streaming would be the real fix and is not available over Signal, so the next
/// best thing is the thing a person does: say what you are doing.
///
/// This deliberately replaces an earlier feature that sent a fixed
/// acknowledgement the moment a message arrived. The owner's verdict on that was
/// "they sound very fake and don't make sense", and they were right, for a
/// reason worth writing down: it fired *before* the model had decided anything,
/// so it was guessing. A turn that says "let me look that up" and then answers
/// from memory has told the owner something untrue about itself.
///
/// So nothing is said until the model has committed to a tool, and what gets
/// said is derived from the tool it actually chose. "Hang on, checking" is a
/// promise the appliance is already keeping.
public enum WorkingReply {

    /// The line to send for a set of chosen tools, or `nil` to stay quiet.
    ///
    /// Quiet is the default for anything fast. A `sage_remember` finishes in
    /// milliseconds, so announcing it would put two messages in the thread where
    /// one would do — noise, in a Note to Self the owner also uses for real
    /// notes.
    public static func line(forTools tools: [String]) -> String? {
        guard let primary = tools.first else { return nil }

        switch primary {
        case "web_search":
            return "Looking that up online — give me a few seconds."

        case "sage_recall", "sage_timeline", "sage_list", "sage_corroborate":
            return "Digging through my memory, hang on."

        case "sage_backlog", "sage_inbox":
            return "Checking that now, one moment."

        case "sage_pipe", "sage_find_agent":
            // The only genuinely long one: another agent has to pick it up,
            // do the work, and come back. Worth setting expectations wider.
            return "Sure — sending that over now. I'll come back to you when it lands."

        case "sage_status", "sage_federation", "sage_scope_list", "sage_scope_get":
            return "Checking the network, one sec."

        case "sage_gov_propose", "sage_gov_vote", "sage_gov_status":
            return "Working on the governance side, hang on."

        default:
            // Writes (sage_remember, sage_task, sage_rename, sage_link…) return
            // fast enough that the answer beats the acknowledgement.
            return nil
        }
    }
}
