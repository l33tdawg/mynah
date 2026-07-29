import Foundation

/// Why Claude Code and Codex are detected on this Mac and still not on the menu.
///
/// ## Why this is not a card
///
/// It was one — two greyed rows in the brain picker, each carrying the sentence
/// below as its unavailability reason. The reasoning was that a disabled card
/// answers the question in the place it is asked, and the owner had asked it:
/// *"we have codex and claude installed clearly; i'm using you right — yet it
/// thinks we don't"*.
///
/// The sentence was true and the placement was what made him ask. **A row in a
/// picker is a claim that this is a thing you might choose** — everything else
/// on that screen is. These two are not and will not be, so grey read as "not
/// found on this Mac" no matter what the row said underneath, because grey means
/// exactly that everywhere else. We put the answer next to the thing generating
/// the question and called it helping.
///
/// So the offer is withdrawn and the answer moved somewhere it is looked for
/// rather than tripped over. Removing the card removes most of the asking.
///
/// ## Why it will not become offerable
///
/// `claude -p` is not a model endpoint. It is an assistant with its own system
/// prompt, its own tools and its own `--mcp-config`, so it does not emit tool
/// calls for `ToolLoop` to run — it runs its own. Driving it would nest an agent
/// inside an agent and bypass the allowlist, the reply style and the turn budget
/// that make this an appliance.
///
/// Handing whole conversations to it is a real and possibly good idea. It is a
/// different product, not this option, and shipping it as "coming" would be the
/// permanent "soon" that Google's withdrawn sign-in card already taught us not
/// to leave on a first screen.
///
/// ## Why the measurement is in the copy
///
/// A verdict invites re-litigation in six months; a number tells whoever
/// re-opens this to re-measure rather than re-argue. If `claude -p` ever answers
/// in a fifth of a second on a small context, the sentence below is what should
/// stop being true first.
///
/// Deliberately kept: `AgentCLIKind`, the probe that finds these, and
/// `BrainSetupOptionID.claudeCodeCLI` / `.codexCLI` with their backend plans.
/// A build shipped these as selectable, so `cli.claude-code` may be on disk as
/// somebody's recorded choice — and an unreadable choice is indistinguishable
/// from no choice, which would send them back through setup with a working brain
/// already configured. Withdrawing an offer is not withdrawing an identity.
public enum AgentCLINotOffered {

    /// Leads with the detection, because that is the half the owner doubted.
    public static func explanation(for kind: AgentCLIKind) -> String {
        let name = kind.displayName
        let seen = "Mynah can see \(name) on this Mac and can't think through it."
        let what = "\(name) is an assistant in its own right rather than a model Mynah can "
            + "drive — it brings its own tools, its own memory and its own instructions."
        let measured = "Measured here in July 2026, it took 4.4 seconds and about 26,000 "
            + "tokens of context to answer \"ok\", before doing any work."
        let instead = "Mynah uses your \(kind.vendorName) key directly instead."
        return [seen, what, measured, instead].joined(separator: " ")
    }

    /// The heading this sits under, for whichever surface shows it.
    public static func heading(for kinds: [AgentCLIKind]) -> String {
        let names = kinds.map(\.displayName)
        switch names.count {
        case 0: return ""
        case 1: return "Why \(names[0]) isn't an option"
        default: return "Why \(names.joined(separator: " and ")) aren't options"
        }
    }
}
