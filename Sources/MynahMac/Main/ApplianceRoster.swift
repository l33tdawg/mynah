import Observation
import OSLog
import SageVoiceCore
import SwiftUI

private let rosterLog = MynahLog(category: "roster")

/// Who Mynah can reach, fetched once when the app starts.
///
/// **The owner's ruling, and it resolves a contradiction rather than working
/// around one:**
///
/// > "don't get the agents that way — let mynah get it from mcp or we do it at
/// > app boot; that is more logical — **you only see the agents you can
/// > actually talk to**"
///
/// He caught the product contradicting itself: twenty cards on the Agents page
/// beside a Mynah that told him over Signal it could see nobody. Two surfaces
/// answering the same question from different places, one of them asking as
/// nobody at all.
///
/// ## Why this is a store and not a fetch
///
/// The page used to read `GET /v1/agents` on **every appearance**, unsigned.
/// That is the shape his ruling is against — an app asking a question as no
/// identity, repeatedly, and rendering the stranger's answer as a fact about
/// him. One fetch at launch makes it a *startup fact* about what Mynah can
/// reach, which is what the page is actually for.
///
/// A roster a few hours stale is fine. The failure this avoids is not staleness.
///
/// ## Why REST still supplies the names — and why the old reason was wrong
///
/// This said: *"There is no MCP enumeration to move to. `sage_find_agent` needs
/// a name and answers about one agent; `sage_status.by_agent` gives ids with no
/// names, roles or clearances."*
///
/// **Both halves of that are false.** `by_agent` does not appear anywhere in
/// 11.17.x's tool surface — a caller-scoped `sage_status` is forbidden from
/// returning per-agent breakdowns at all, which SAGE's own route-security test
/// asserts. And `sage_directory` *is* the enumeration it says does not exist:
/// its own reference describes it as listing "recipients this signed caller is
/// currently authorized to address", each row carrying display name, immutable
/// registered name, provider, exact `agent_id`, and local/federated provenance.
/// That is the owner's ruling — *"you only see the agents you can actually talk
/// to"* — answered in one signed call.
///
/// So the honest position today is that `MCPAgentDirectory` takes candidate
/// *names* from REST and puts every one to `sage_find_agent` for the verdict,
/// and `sage_directory` would replace both halves with a single signed read.
/// That change is worth making and is deliberately not being made here: #51 was
/// about a comment asserting something untrue, and swapping the source would
/// change what this page shows the owner, which is a decision to take on purpose
/// rather than as a side effect of correcting prose. Filed separately.
///
/// `AgentDirectorySource` is the seam. One type conforms, this store's
/// initialiser takes it, and nothing else changes — the same shape as
/// `AgentSubjectSource`, and for the same reason.
@MainActor
@Observable
final class ApplianceRoster {

    /// **`unavailable` is not `ready(.empty)` and the two must never collapse.**
    ///
    /// A boot fetch that failed means the app does not know who is out there.
    /// An empty roster means it asked and there is nobody. Rendering the first
    /// as the second is the substitution this codebase has spent a day removing
    /// — the scoped backlog reading as an empty plate, the ghost key reading as
    /// an empty memory, a silently filtered recall reading as a complete
    /// answer. The owner has caught it twice himself.
    enum Phase: Equatable {
        /// Boot has not run yet. Draws nothing — a screen that has not asked
        /// must not answer.
        case notAsked
        case loading
        case ready(AgentRoster)
        case unavailable(AgentTrouble)
    }

    static let shared = ApplianceRoster()

    private(set) var phase: Phase = .notAsked

    private let source: any AgentDirectorySource

    init(source: any AgentDirectorySource = MCPAgentDirectory()) {
        self.source = source
    }

    /// The roster, or an empty one while there is nothing to show.
    ///
    /// Callers that need to tell *unavailable* from *empty* read `phase`. This
    /// exists so a view drawing rows does not have to unwrap on every access,
    /// and it is deliberately not the only accessor.
    var roster: AgentRoster {
        if case .ready(let roster) = phase { return roster }
        return .empty
    }

    /// Fetches once. Safe to call from anywhere; later calls are free.
    ///
    /// Idempotent on *success* rather than on having-been-called: a boot that
    /// failed because the node was still starting up should be retryable when
    /// the owner reaches the page, or a slow launch would cost them the roster
    /// for the whole session.
    func loadOnce() async {
        switch phase {
        case .ready, .loading: return
        case .notAsked, .unavailable: break
        }
        await reload()
    }

    /// The owner's own retry, from the failure state's button.
    func reload() async {
        phase = .loading
        do {
            phase = .ready(try await source.roster())
        } catch let trouble as AgentTrouble {
            phase = .unavailable(trouble)
        } catch {
            rosterLog.error("roster failed: \(String(describing: error))")
            phase = .unavailable(.unreachable)
        }
    }
}
