import Foundation

/// Where remembered text comes from, for the dictation profile.
///
/// The bridge's last link: `sage_recall` in, plain strings out, fed to
/// `DictationProfileStore`. It exists as its own type so the store keeps having
/// no opinion about MCP — it composes text into a profile and nothing else.
///
/// ## A refusal must look exactly like an empty corpus
///
/// This is the whole design constraint, and it is not hypothetical: on the
/// owner's machine today Mynah carries capability mask 30 and `sage_recall`
/// answers with a refusal rather than an empty list. He is going to run this
/// build in that state, for days, until the SAGE fix lands.
///
/// So every failure here returns `[]`. Not a thrown error, not a surfaced
/// message, not a log line per utterance — an empty corpus, which the profile
/// builder already treats as "no repairs" and which a test pins as being
/// byte-identical to today's behaviour.
///
/// The temptation to report it is real, and wrong twice over. Once because the
/// owner cannot act on it, and once because a complaint about memory would
/// arrive attached to a voice note, which is the least related place it could
/// possibly appear.
///
/// The original version of this comment justified the silence by saying the
/// owner "already knows his agent cannot read its memories, it is on the Agents
/// page". **Both halves were wrong.** The appliance reads this node freely —
/// its capability mask denies writes and pipes, not reads — and the Agents page
/// was carrying that false claim rather than establishing it. Left here as a
/// marker: a comment that leans on another screen's wording inherits that
/// screen's mistakes, and this one outlived the sentence it cited.
public struct SageMemoryVocabularySource: Sendable {

    /// How many memories to mine. Recall returns most-relevant first, and the
    /// vocabulary keeps the terms mentioned in the most separate memories, so
    /// this is a sample rather than a corpus — enough for the names the owner
    /// uses constantly to appear repeatedly, without dragging five figures of
    /// text through an actor on start-up.
    public static let sampleSize = 200

    /// Deliberately broad. The goal is a wide sample of how the owner writes,
    /// not an answer to a question — anything that biases towards one subject
    /// would teach the recogniser that subject's jargon and no other.
    public static let query = "projects, people, agents, tools and place names"

    private let tools: any ToolProviding

    public init(tools: any ToolProviding) {
        self.tools = tools
    }

    /// The source closure `DictationProfileStore.use(source:)` wants.
    public func callAsFunction() async -> [String] {
        do {
            let reply = try await tools.call(
                name: "sage_recall",
                arguments: [
                    "query": .string(Self.query),
                    "limit": .int(Self.sampleSize)
                ]
            )
            return Self.texts(in: reply)
        } catch {
            // Refused, unreachable, unregistered, or the node is not running.
            // All four are the same answer to the only question being asked:
            // there is nothing to learn from right now.
            return []
        }
    }

    /// Pulls memory content out of whatever shape recall replied with.
    ///
    /// Tolerant on purpose. The reply is a tool result rendered for a language
    /// model rather than a stable API — the useful text may be under
    /// `memories`, `results`, or simply be the whole string. Guessing wrong
    /// costs an empty vocabulary, which is the state this already degrades to,
    /// so a lenient parser is strictly better than a strict one that throws.
    static func texts(in reply: String) -> [String] {
        guard let data = reply.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            // Not JSON. The whole reply is the sample — mining coinages out of
            // prose is exactly what the vocabulary does anyway.
            return reply.isEmpty ? [] : [reply]
        }

        if let list = root as? [[String: Any]] {
            return list.compactMap { content(of: $0) }
        }
        if let object = root as? [String: Any] {
            for key in ["memories", "results", "recalled", "items"] {
                if let list = object[key] as? [[String: Any]] {
                    return list.compactMap { content(of: $0) }
                }
            }
            if let single = content(of: object) { return [single] }
        }
        return []
    }

    private static func content(of memory: [String: Any]) -> String? {
        for key in ["content", "text", "memory", "observation", "summary"] {
            if let value = memory[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
