import XCTest
@testable import SageVoiceCore

/// The rules that make a stored memory reachable.
///
/// Semantic embeddings fixed *whether* the right memory comes back. They do
/// nothing about *whether the model looks*, and those are separate failures with
/// the same symptom. Measured on the appliance after the embedding switch, with
/// every shop already recallable in one call:
///
///     "write me a note listing every shop we discussed across Thailand,
///      Philippines and Japan"
///     -> 1 iteration, tools: none, "This is a new conversation so I don't have
///        memory of our prior discussion about these topics."
///
/// A 4B model reads an empty conversation as an empty memory. `sage_recall` was
/// right there, offered, in a catalogue of 18. Nothing in the prompt connected
/// "we discussed" to it, so it asked the owner to retype what SAGE already held.
///
/// These assertions are deliberately about wording. The prompt is the only place
/// this behaviour lives — there is no code path to test — so a rule nobody
/// asserts is a rule the next edit quietly deletes.
final class RecallDisciplineTests: XCTestCase {

    private var prompt: String { BrainPrompts.voiceAgentManager }

    /// The trigger phrases. These are the owner's actual words from the Signal
    /// thread, not invented examples.
    func testThePromptNamesTheWordsThatMeanAnEarlierConversation() {
        for phrase in ["we talked about", "you told me", "the ones from before", "our list"] {
            XCTAssertTrue(
                prompt.contains(phrase),
                "\"\(phrase)\" is how the owner refers to stored memory and the prompt does not mention it"
            )
        }
        XCTAssertTrue(prompt.contains("sage_recall"), "no tool is named as the answer")
    }

    /// The exact refusal that was observed, forbidden by name.
    ///
    /// Same shape as the picture rule ("never say you are unable to look at
    /// pictures"): a capable model denying a capability it has is worse than one
    /// that tries and fails, because the owner has no reason to ask again.
    func testThePromptForbidsClaimingToHaveNoMemory() {
        XCTAssertTrue(
            prompt.contains("Never say you have no record of an earlier conversation"),
            "the model may still answer \"this is a new conversation so I don't have memory\""
        )
        XCTAssertTrue(
            prompt.contains("never ask the owner to repeat something before you have looked"),
            "nothing stops it asking the owner to retype what SAGE already holds"
        )
    }

    /// The owner's own diagnosis: *"the agent can do sage recall as many times as
    /// it needs — it's probably not really doing that."* The log agreed. The turn
    /// that produced the thin document called `sage_recall` exactly once, then
    /// spent three iterations on consolation web searches.
    func testThePromptAsksForMoreThanOneRecallBeforeGivingUp() {
        XCTAssertTrue(prompt.contains("One recall is rarely enough"))
        XCTAssertTrue(
            prompt.contains("call sage_recall again in different words"),
            "a thin first result still ends the search"
        )
        XCTAssertTrue(
            prompt.contains("before you answer or reach for web_search"),
            "the web is still an equal first choice to the owner's own memory"
        )
    }

    /// Raising the iteration cap to 10 is what makes "recall again" affordable.
    /// At 5, a second and third recall came out of the same budget as the write,
    /// which is how the shop list got truncated in the first place.
    func testThereIsRoomInTheBudgetToActuallyDoThis() {
        XCTAssertGreaterThanOrEqual(
            ToolLoop.defaultMaxIterations,
            8,
            "asking for repeated recall inside a cap that cannot afford it just moves where the turn breaks"
        )
    }

    /// This section cost ~624 characters, taking the prompt from 5,100 to ~5,724.
    ///
    /// `PromptLatencyBudgetTests` owns the ceiling and explains why it is now
    /// 8,000 rather than 6,000 — briefly, the system prompt is the most cacheable
    /// part of the request, so its real cost is a 4B model's attention rather
    /// than the owner's seconds. This assertion just keeps the arithmetic above
    /// honest: if the section is edited down to nothing, the sentence claiming it
    /// cost 624 characters should stop being true out loud.
    func testTheseRulesCostWhatTheDocSaysTheyCost() {
        XCTAssertGreaterThan(
            prompt.count,
            5_400,
            "the recall section appears to have been cut — the 624-character note above is now wrong"
        )
        XCTAssertLessThanOrEqual(prompt.count, PromptLatencyBudgetTests.systemPromptCharacterBudget)
    }

    // MARK: Corrections

    /// The CODEBLUE conflation, and why it survived being corrected.
    ///
    /// "I'm in Tokyo in November for CODEBLUE" arrived in the same sentence as a
    /// question about eurorack, and `sage_remember` stored them fused. The owner
    /// corrected it — "CODEBLUE is not eurorack related" — and that turn called
    /// `sage_remember` twice and `sage_forget` zero times. Both versions stayed
    /// stored, and the next morning recall returned the contradiction and the
    /// model merged it into a document heading reading "CODEBLUE Japan /
    /// Festival of Modular Venues".
    ///
    /// Semantic embeddings made the correction reachable, which is why this
    /// currently resolves in the owner's favour. It resolves by luck: the right
    /// memory happens to outrank the wrong one. The wrong one is still there.
    func testThePromptTreatsACorrectionAsAReplacement() {
        XCTAssertTrue(
            prompt.contains("A correction replaces a memory, it does not add one"),
            "a correction still stores a second, contradicting memory"
        )
        XCTAssertTrue(prompt.contains("sage_forget"), "no tool is named for removing the wrong memory")
        XCTAssertTrue(
            prompt.contains("leaves both versions stored"),
            "nothing explains the consequence, which is the part that makes the rule stick"
        )
    }

    /// The other half of the same bug: the memory was wrong because it was
    /// stored fused in the first place.
    ///
    /// This used to require the phrase "two memories in two domains", and that
    /// half of the instruction is now deliberately gone. Under app-v22 an agent
    /// may only write a domain it owns, so a domain invented per subject is a
    /// memory that is refused and lost — the prompt was teaching the model to
    /// destroy the very memories this rule exists to keep. One subject per
    /// memory survives; splitting by domain is replaced by tags.
    func testThePromptAsksForOneSubjectPerMemoryWithoutSplittingTheDomain() {
        XCTAssertTrue(prompt.contains("Store one subject per memory"))
        XCTAssertTrue(
            prompt.contains("that is two memories, not one"),
            "nothing tells it what to do with a sentence carrying two subjects"
        )
        XCTAssertFalse(
            prompt.contains("two memories in two domains"),
            "a domain invented per subject cannot be written and the memory is lost"
        )
        XCTAssertTrue(
            prompt.contains("Put the subject in the tags instead"),
            "removing the domain split leaves nothing carrying the subject"
        )
    }

    /// A rule naming a tool the model cannot see is a rule that cannot be
    /// followed. `sage_forget` is in the allowlist — this fails if someone trims
    /// the catalogue without reading the prompt.
    func testTheToolTheRuleNamesIsActuallyOffered() {
        XCTAssertTrue(
            BrainPrompts.sageToolCuration.contains("sage_forget"),
            "the correction rule names a tool the model is never given"
        )
    }
}

// MARK: - Answering the question that was asked

/// The owner asked *"what agents can you see?"* and got a careful report about
/// **federated connections** — zero remote SAGEs, operator configuration needed
/// — while the Agents page beside it listed twenty agents on his Mac. His words:
/// *"these cards are still showing up despite it saying it's not being able to
/// see any other agents, which is weird."*
///
/// It is not a routing mistake. Verified against the tool reference:
/// `sage_find_agent` requires a `name`, `sage_status` returns ids and counts
/// with no names, and `sage_federation` takes **no parameters at all** — so it
/// is the only agent-shaped tool the model can call without already knowing the
/// answer. It reached for the one instrument it had.
///
/// Which made this a limitation rendered as a finding. The prompt could not
/// conjure the missing tool; it could only stop the model dressing the absence
/// up as a result.
///
/// **SAGE 11.16.4 shipped the tool, so these tests now assert the opposite of
/// what they used to.** `sage_directory` lists the agents this caller may
/// address — display name, registered name, provider and exact `agent_id`. The
/// rule that survived the change is the federation ban, because that wrong
/// answer was never about a missing capability: it was about reaching for an
/// adjacent tool and reporting its output as though it answered the question.
///
/// **And the same wrong answer came back on 7 August, by a new route.** This
/// used to say `sage_directory` "takes no arguments", as did the prompt. It
/// takes `scope`, and the default is `local` — so asked what was on the
/// *network*, Mynah read a local roster and reported "No federated SAGEs
/// connected" while a federated peer sat on another Mac. Same sentence the ban
/// above exists to prevent, produced this time by the *right* tool answering a
/// narrower question than the one asked. Reported by codex; see
/// `VoiceToolBudget.fitDirectory` for the half of the fix that is not prose.
final class AgentEnumerationHonestyTests: XCTestCase {

    private var prompt: String { BrainPrompts.voiceAgentManager }

    func testThePromptNamesTheToolThatEnumerates() {
        XCTAssertTrue(
            prompt.contains("sage_directory answers both"),
            "the model is not told which tool lists the agents it can address"
        )
        XCTAssertFalse(
            prompt.contains("cannot list the agents on this Mac"),
            "it can now, and a prompt that says otherwise makes it refuse a question it can answer"
        )
    }

    /// **The bug itself.** A local-scoped read cannot answer a question about
    /// the network, and the prompt has to say which scope to ask for — the
    /// default is the wrong one.
    func testThePromptDemandsTheFullScope() {
        XCTAssertTrue(
            prompt.contains(#"{"scope":"all"}"#),
            "the model will take the default, which is this Mac only"
        )
        XCTAssertFalse(
            prompt.contains("It takes no arguments"),
            "this sentence is what produced 'No federated SAGEs connected' on 7 August"
        )
    }

    /// **"I could not see everything" is not "there is nobody else".** The same
    /// distinction as the inbox read in 1.8.5, at the prompt layer: SAGE reports
    /// `complete: false` and `warnings`, and a model that swallows them turns a
    /// partial roster into a confident denial.
    func testThePromptRequiresIncompletenessToBeSpoken() {
        XCTAssertTrue(prompt.contains(#""complete": false"#))
        XCTAssertTrue(prompt.contains("warnings"))
        XCTAssertTrue(
            prompt.contains(#"NEVER turn an incomplete list into "there is nobody else""#),
            "without this the model reports what it could see as what exists"
        )
    }

    /// The recipient may be on another machine, and the default scope hides
    /// them — so the send path needs the same rule as the question path.
    func testTheSendPathAsksForTheFullScopeToo() {
        guard let sending = prompt.range(of: "SENDING WORK TO ANOTHER AGENT"),
              let replied = prompt.range(of: "WHEN ASKED IF ANYONE REPLIED") else {
            return XCTFail("the sending section is not where this test thinks it is")
        }
        let section = String(prompt[sending.lowerBound..<replied.lowerBound])
        XCTAssertTrue(
            section.contains(#"{"scope":"all"}"#),
            "a remote recipient is invisible to the default scope, so the send cannot be addressed"
        )
    }

    /// The wrong answer was confident and adjacent. Naming the tool that
    /// produced it is what stops it being reached for again — and this survives
    /// `sage_directory` existing, because a model that has the right tool can
    /// still reach for the wrong one.
    func testThePromptForbidsAnsweringWithFederation() {
        XCTAssertTrue(prompt.contains("NEVER answer this with sage_federation"))
        XCTAssertTrue(
            prompt.contains("connected *other SAGEs*"),
            "does not say what federation actually reports, so the ban looks arbitrary"
        )
    }

    /// **A list is what stops a guess.** Asked to send a note to "you", a 4B
    /// matched the substring with `sage_find_agent` and piped the owner's
    /// messages to two unrelated Claude registrations. Choosing from an
    /// enumerated roster is not the same act as searching by name, and only one
    /// of the two can invent a recipient.
    func testSendingWorkStartsFromTheListRatherThanASearch() {
        XCTAssertTrue(prompt.contains("call sage_directory first"))
        XCTAssertTrue(
            prompt.contains("exact agent_id from that list"),
            "without this the model pipes to the name the owner spoke"
        )
        XCTAssertTrue(
            prompt.contains("Never guess an agent_id"),
            "the failure was a guess that looked like a match"
        )
    }
}

