import Foundation

/// How much tool traffic is allowed into a voice turn's context.
///
/// **Measured, not guessed.** On this Mac, 2026-07-29, going from 14 tools to
/// 27 added ~9.5 KB of schema and cost **3.4 s per turn** on `qwen3.5:4b`
/// (`scripts/measure-tool-routing.py`). That is ~0.36 ms per byte the model has
/// to read before it can begin speaking.
///
/// `sage_status` returns **31,321 bytes** on the owner's node — 851
/// `"subject": count` pairs, 93% of the payload. At the rate above that is
/// roughly eleven seconds of prefill, and it matches what his log shows: his
/// `sage_status` turns take 32.9 s and 41.7 s against 17.2 s for a turn with no
/// tool, while `sage_status` **itself returns in 0.37 s**. The tool is fast. The
/// reading is what costs him.
///
/// A voice appliance cannot speak 851 subject names. Every byte past what it
/// could say aloud is pure latency, so this is the cheapest second in the
/// product to buy back.
///
/// ## Two levers, and the boundary between them
///
/// This type only governs **what Mynah asks for and what Mynah accepts**. It
/// does not change what SAGE returns to anyone else — that node serves other
/// agents and is not ours to reshape.
///
/// 1. `clamp(arguments:)` — trims the request. `sage_recall` takes `top_k` and
///    `sage_list` takes `limit`, so for those the cheapest fix is not to ask for
///    so much in the first place.
/// 2. `fit(_:)` — trims the reply. `sage_status`, `sage_backlog` and
///    `sage_timeline` take **no size parameter at all**, so asking differently
///    cannot help; the only lever left on our side of the boundary is how much
///    of the answer we feed our own model.
public enum VoiceToolBudget {

    /// The most a *directory-shaped* result may contribute on a local model.
    ///
    /// 2,000 bytes ≈ 0.7 s of prefill at the measured rate — a cost worth paying
    /// for an answer, where 31 KB (~11 s) is not. It is deliberately generous
    /// against what a spoken reply can carry: a voice answer is a sentence or
    /// two, and this allows far more than that so the model has room to choose.
    public static let resultByteBudget = 2_000

    // MARK: - Not every result is a directory

    /// Tools whose answer *is* the owner's content rather than a listing of it.
    ///
    /// **One number for every tool was wrong, and it showed on the owner's
    /// phone.** He asked what his agents had sent; Codex had written two long
    /// messages; the second was cut at 2 KB and Mynah reported *"the second
    /// message got truncated by the system, so I may have missed its tail
    /// end."* Honest, and useless — the message was the errand.
    ///
    /// The distinction that matters is not size, it is what the bytes are.
    /// `sage_status` truncated loses 839 subject names nobody could hear read
    /// aloud, and the trim keeps the stated totals so the answer stays true. An
    /// agent's message truncated loses the thing the owner asked for, and there
    /// is nothing left to state instead.
    static let contentTools: Set<String> = [
        // Another agent's own words, arbitrary length, no summary possible.
        "sage_inbox",
        // The owner's own memories, already capped to four by `clamp`.
        "sage_recall",
        // The owner's own document, which they asked to have read back.
        "read_note",
        // Pages the model went and fetched because the answer is in them.
        "web_search"
    ]

    /// The budget for one result.
    ///
    /// Two axes, because two different things were being conflated:
    ///
    /// - **What the result is.** Content gets three times a directory's room.
    /// - **Which brain is reading it.** The 2 KB figure is prefill arithmetic
    ///   for `qwen3.5:4b` *on this Mac*: 0.36 ms per byte, so 31 KB is eleven
    ///   seconds of silence before it can speak. Against a hosted model that
    ///   arithmetic does not hold — the prefill happens on somebody else's
    ///   hardware, in parallel, and the honest cost is a few tokens. Holding a
    ///   cloud brain to a local model's latency budget buys nothing and loses
    ///   the tail of every long answer.
    /// **The multipliers are gone, and losing them is the point.** This was
    /// `resultByteBudget` times one of ×1/×3/×8/×16, which meant the hosted
    /// content ceiling — 32,000 — existed only as arithmetic nobody could read
    /// off the page. Meanwhile `ToolLoop` cut every result again at a hardcoded
    /// 6,000, which is `resultByteBudget × 3` by coincidence rather than by
    /// agreement, so the two numbers matched on device and silently cancelled
    /// each other everywhere else. Two numbers that happen to be equal, in
    /// different units, in different files, are not one rule. See `BrainTier`.
    public static func budget(forTool tool: String, brain: BrainCapabilities) -> Int {
        brain.toolResultBytes(carryingContent: contentTools.contains(tool))
    }

    /// The most any tool may be asked to return.
    ///
    /// The owner's instruction was *"don't return k10 bro — return a smaller k
    /// that would immediately help with not using so much context and tool
    /// calls."* The second half is his insight and not one we had: an oversized
    /// result does not merely cost prefill, it **provokes follow-up calls** —
    /// a model handed ten partial hits goes looking for the eleventh, while one
    /// handed four good ones answers. On a phone where each extra turn is 16 s+,
    /// that compounds.
    ///
    /// Four, because a spoken answer can carry about three memories and the
    /// model should have one more than it needs rather than exactly enough.
    public static let maxResultCount = 4

    /// Size arguments, by the name each tool happens to use.
    private static let countArguments = ["top_k", "limit", "count", "max_results", "n"]

    // MARK: What Mynah asks for

    /// Caps any size argument the model chose.
    ///
    /// **A schema default is not a mechanism.** `sage_recall` advertises
    /// `top_k` default 5 and the model may pass any integer it likes; lowering
    /// the advertised default would leave a request the model can talk itself
    /// out of. This runs on the way out, after the model has decided, so the
    /// ceiling holds whatever it asked for.
    ///
    /// Only ever lowers. A model that asks for 2 gets 2 — it had a reason, and
    /// raising it to a house number would be this function inventing a request
    /// nobody made.
    public static func clamp(arguments: [String: JSONValue]) -> [String: JSONValue] {
        var clamped = arguments
        for key in countArguments {
            guard let value = arguments[key]?.intValue, value > maxResultCount else { continue }
            clamped[key] = .int(maxResultCount)
        }
        return clamped
    }

    // MARK: What Mynah accepts

    /// Trims a tool result to the budget, **saying what it removed**.
    ///
    /// The danger in truncation is not that the model says less — it is that the
    /// model says something *false*. Cut 851 subjects to 12 silently and the
    /// honest-sounding answer becomes "you have twelve subjects", which is
    /// wrong, and wrong in the confident register this appliance speaks in. It
    /// would be the day's recurring defect one more time: an absence read as an
    /// answer.
    ///
    /// So a trimmed result always carries the count it was trimmed from. The
    /// model is then able to say "about thirteen thousand memories across eight
    /// hundred and fifty-one subjects" — which is both shorter *and* more
    /// accurate than reciting a directory it could never finish.
    /// - Parameters:
    ///   - tool: which tool answered, because a directory and the owner's own
    ///     content do not deserve the same room. See `contentTools`.
    ///   - brain: the ceilings for the brain reading this. The whole budget is
    ///     prefill arithmetic, and that arithmetic is about a local model — so
    ///     defaulting to `.onDevice` keeps the tight number for any caller that
    ///     has not been told which brain is asking. Erring tight is the safe
    ///     direction: a result cut too short says so in the sentence below,
    ///     while one left too long is eleven seconds of silence.
    public static func fit(
        _ result: String,
        tool: String = "",
        brain: BrainCapabilities = .onDevice
    ) -> String {
        let allowance = budget(forTool: tool, brain: brain)
        guard result.utf8.count > allowance else { return result }

        if let trimmed = fitCountedEntries(result) { return trimmed }

        // Unrecognised shape: keep the head, and be explicit about the tail
        // rather than letting the model treat a severed sentence as the whole
        // answer.
        let head = String(decoding: result.utf8.prefix(allowance), as: UTF8.self)
        let dropped = result.utf8.count - head.utf8.count
        return head + "\n\n[Mynah kept the first \(head.utf8.count) characters of this result and "
            + "left \(dropped) unread, to answer sooner. Say so if the answer looks incomplete.]"
    }

    /// The subject breakdown, which is what actually blows the budget here —
    /// `by_domain` is 93% of `sage_status` on the owner's node.
    ///
    /// **This function's first draft shipped a lie, and the shape of that
    /// mistake is worth keeping.** It matched every `"name": count` line and
    /// summed them, which swept up `db_size_bytes: 244154368` alongside the
    /// subjects and announced *"244,215,560 memories"*. The model then said
    /// "over two hundred million memories" — faithfully, because it was reading
    /// what we handed it. The un-budgeted model got the real figure right.
    /// **Trading twenty-two seconds for a wrong answer is a worse deal than the
    /// twenty-two seconds**, and it took a measurement to see it, because the
    /// summary looked entirely plausible.
    ///
    /// The rule that came out of it: **never compute a total the payload already
    /// states.** `sage_status` reports `total_memories` itself. Summing is how a
    /// summariser invents a fact, and an invented fact spoken confidently is the
    /// one failure mode this appliance cannot afford.
    ///
    /// So this reads the stated total, lists only `by_domain` — never
    /// `by_agent`, whose keys are 64-character hashes no one can say out loud —
    /// and if it cannot find the stated total it declines to give one rather
    /// than deriving it.
    private static func fitCountedEntries(_ result: String) -> String? {
        guard let domains = countedEntries(in: result, under: "by_domain"),
              domains.count >= 20 else { return nil }

        let top = domains.sorted { $0.count > $1.count }.prefix(12)
        let listed = top
            .map { "\"\($0.name.replacingOccurrences(of: "\"", with: "'"))\": \($0.count)" }
            .joined(separator: ", ")

        // Stated, not summed. Absent rather than guessed.
        let stated = statedInteger(named: "total_memories", in: result)
            .map { "\"total_memories\": \($0), " } ?? ""

        // **Shaped like the tool's own output, not like prose about it.**
        //
        // The first working version summarised in sentences and added a
        // bracketed note explaining the trim. Measured on `qwen3.5:4b`, that
        // reproducibly made the model *stop using the result*: it answered "I
        // don't hold personal experiences like a human does" — the generic
        // deflection — and took 79-103 s doing it, against 9 s for the same
        // facts as JSON. A plain 2 KB head-truncation of the original failed the
        // same way.
        //
        // The reading: a tool result that looks like commentary gets treated as
        // commentary. Keeping the envelope the model expects is what makes a
        // smaller result still count as an answer, so the trim stays inside the
        // shape rather than replacing it.
        return "{\(stated)\"subjects\": \(domains.count), "
            + "\"largest_subjects\": {\(listed)}, "
            + "\"note\": \"truncated to the largest \(top.count) of \(domains.count) subjects\"}"
    }

    /// A scalar the payload states about itself.
    private static func statedInteger(named key: String, in result: String) -> Int? {
        let pattern = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*(\\d+)")
        guard let pattern,
              let match = pattern.firstMatch(
                in: result, range: NSRange(result.startIndex..., in: result)
              ),
              let range = Range(match.range(at: 1), in: result) else { return nil }
        return Int(result[range])
    }

    /// `"name": count` pairs inside one named object, and nowhere else.
    ///
    /// Scoped by brace depth rather than by a global line match, which is what
    /// let sibling scalars and the `by_agent` hashes contaminate the first
    /// version.
    private static func countedEntries(
        in result: String,
        under key: String
    ) -> [(name: String, count: Int)]? {
        guard let keyRange = result.range(of: "\"\(key)\"") ,
              let openBrace = result[keyRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var end: String.Index?
        var index = openBrace
        while index < result.endIndex {
            let character = result[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = result.index(after: index)
        }
        guard let end else { return nil }

        let body = String(result[result.index(after: openBrace)..<end])
        let pattern = try? NSRegularExpression(
            pattern: #""([^"]+)"\s*:\s*(\d+)"#
        )
        guard let pattern else { return nil }

        var entries: [(name: String, count: Int)] = []
        for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let nameRange = Range(match.range(at: 1), in: body),
                  let countRange = Range(match.range(at: 2), in: body),
                  let count = Int(body[countRange]) else { continue }
            entries.append((String(body[nameRange]), count))
        }
        return entries.isEmpty ? nil : entries
    }
}
