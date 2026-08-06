import Foundation

/// **The sentence the caller hears when something was queued.**
///
/// The tool result tells the model to say this itself, and usually it will.
/// This is the backstop for when it does not — and the reason there is a
/// backstop at all is that the failure is silent and lands on the owner: they
/// asked for something, heard nothing about it, and a file arrives an hour
/// later with no explanation.
///
/// The same shape `SpokenReply` already uses for the link notice, and for the
/// same reason: a thing the appliance did on the caller's behalf has to be
/// audible in the call, not only visible afterwards.
public enum AfterTheCall {

    static let promise = "I'll take care of that after we hang up."

    /// Adds the promise unless the reply already makes it.
    ///
    /// The check is deliberately loose. Over-promising costs a redundant
    /// half-sentence; under-promising is the failure this exists to prevent, so
    /// where the two are in tension this leans towards saying it twice.
    public static func promising(_ reply: String) -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alreadyPromises(trimmed) else { return reply }
        guard !trimmed.isEmpty else { return promise }
        let needsStop = !(trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?"))
        return trimmed + (needsStop ? ". " : " ") + promise
    }

    static func alreadyPromises(_ reply: String) -> Bool {
        let lowered = reply.lowercased()
        // Phrases a model actually produces when it has understood the tool
        // result. Matching on intent rather than on an exact sentence, because
        // the prompt asks for one line in its own words.
        let tells = [
            "after we hang up",
            "after the call",
            "after this call",
            "once we're done",
            "once we are done",
            "when we hang up",
            "once the call"
        ]
        return tells.contains { lowered.contains($0) }
    }
}
