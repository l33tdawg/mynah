import Foundation

// MARK: - What an agent has been given access to
//
// The owner asked for subject pills on the agents page: for each agent, which
// subjects it can reach. It is the right thing to want — "what can this thing
// see" is the question the whole screen is circling — and **the node cannot
// answer it yet.** Listing another agent's grants needs an endpoint that
// arrives in SAGE 11.15.0.
//
// So this is a seam, and the shape of the seam is the whole design:
//
// 1. **A pill for a relationship the node cannot report shows nothing.** Not
//    "unknown", not a dash, not a spinner that never resolves. Those are three
//    ways of drawing a fact the app does not have, and this screen has spent the
//    day learning what that costs — a roster that said "zero connected agents"
//    over twenty agents, a memories page that showed an empty state because it
//    signed as an agent that did not exist. An absence rendered as an answer is
//    the defect this product keeps finding in itself.
// 2. **The page never waits on it.** The roster and the standing facts are
//    real today; blocking them on an endpoint that returns nothing would trade
//    working content for a loading state.
// 3. **The response shape is not invented here.** `subjects(forAgent:)` returns
//    strings because that is what a subject is everywhere else in this app —
//    `SageRitual.memoryDomain` is a string, `FederationHelp.applianceDomain` is
//    a string. Nothing is decoded, no field names are guessed, and the
//    implementation that will do the decoding does not exist. When the endpoint
//    lands, one type conforms and the view is untouched.

/// Which subjects an agent can reach.
protocol AgentSubjectSource: Sendable {

    /// - Returns: the subjects this agent has been granted, or `nil` when the
    ///   node cannot answer the question at all.
    ///
    ///   **`nil` and `[]` are different and the view treats them differently.**
    ///   `[]` is a node that answered and said "none", which is a fact worth
    ///   drawing. `nil` is a node that cannot be asked, which is not a fact
    ///   about the agent and must not be drawn as one. Collapsing the two would
    ///   turn "we cannot see" into "there are none" — the exact substitution
    ///   that made an empty memories page look like an empty brain.
    func subjects(forAgent id: String) async -> [String]?
}

/// What every node the owner can currently be running says: nothing.
///
/// Deliberately not a stub to be replaced — it is the correct implementation
/// for every SAGE before 11.15.0, and it stays correct for them afterwards.
/// When the endpoint exists this gains a sibling and a version check chooses
/// between them; it does not get deleted.
struct UnaskableSubjects: AgentSubjectSource {
    func subjects(forAgent id: String) async -> [String]? { nil }
}
