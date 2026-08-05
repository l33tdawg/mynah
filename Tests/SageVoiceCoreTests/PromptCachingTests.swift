import XCTest
@testable import SageVoiceCore

/// Anthropic prompt caching, and the warm-up that must not run against it.
///
/// ## Two comments claimed this worked and it did not
///
/// `PromptStableJSON`'s entire reason for sorting keys is that "every prompt
/// cache worth having — llama.cpp's prefix cache, Anthropic's `cache_control`,
/// DeepSeek's context cache — matches on a *byte* prefix", and `AnthropicBackend`
/// repeats the claim beside the encoder. The byte-stability work was real and
/// was a prerequisite. The field that uses it was never sent: `cache_control`
/// appeared nowhere in `Sources/`.
///
/// ## Why the breakpoint is on the system block
///
/// Anthropic's cached prefix runs tools → system → messages, and a breakpoint
/// caches everything up to and including its own block. `claude-haiku-4-5` will
/// not cache a prefix under 4,096 tokens, and this appliance's system prompt is
/// about 1,900 — so a system-only prefix would silently never cache. With the
/// tool schemas ahead of it the prefix clears the minimum, which is why the
/// breakpoint sits on system rather than on the last tool.
final class PromptCachingTests: XCTestCase {

    // MARK: The breakpoint

    func testTheSystemPromptCarriesAnEphemeralCacheBreakpoint() throws {
        let blocks = AnthropicBackend.cachedSystemBlocks("you are a helpful appliance")

        XCTAssertEqual(blocks.count, 1, "one stable segment, so one breakpoint")

        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block["type"] as? String, "text")
        XCTAssertEqual(
            block["text"] as? String, "you are a helpful appliance",
            "the prompt itself did not survive being wrapped"
        )

        let control = block["cache_control"] as? [String: Any]
        XCTAssertEqual(
            control?["type"] as? String, "ephemeral",
            """
            no cache breakpoint on the system block, so every hosted turn \
            re-reads the whole tool catalogue and system prompt at full price — \
            which is what PromptStableJSON's key sorting was groundwork for
            """
        )
    }

    /// It has to survive `PromptStableJSON`, which is what actually goes on the
    /// wire — a nested dictionary it could not encode would throw at send time,
    /// on the owner's first hosted turn rather than here.
    func testTheBreakpointSurvivesTheByteStableEncoder() throws {
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "system": AnthropicBackend.cachedSystemBlocks("you are a helpful appliance")
        ]

        let data = try PromptStableJSON.data(from: body)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("cache_control"), text)
        XCTAssertTrue(text.contains("ephemeral"), text)
    }

    /// Byte-identical twice, which is the whole premise: a prefix that
    /// re-serialises differently is a prefix no cache can match.
    func testTheSameSystemPromptEncodesToTheSameBytes() throws {
        let once = try PromptStableJSON.data(
            from: ["system": AnthropicBackend.cachedSystemBlocks("stable")]
        )
        let twice = try PromptStableJSON.data(
            from: ["system": AnthropicBackend.cachedSystemBlocks("stable")]
        )

        XCTAssertEqual(once, twice, "the cached prefix does not serialise identically")
    }

    /// **The call surface has the same call site and it was missed.**
    ///
    /// `//call` is refused unless `brain.holdsARealtimeCall`, which is false on
    /// device — so a call is always hosted, and an ungated anchor there was a
    /// second billed full-context request after every spoken turn. The daemon's
    /// twin got the guard hours earlier the same day; this one did not. Seventh
    /// instance in this audit of a fix landing on one of two identical places.
    func testTheCallSurfaceDoesNotAnchorAHostedBrainEither() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/sage-voiced/main.swift"),
            encoding: .utf8
        )
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)

        XCTAssertTrue(
            code.contains("onTurnSpoken"),
            "this test is reading the wrong file — the call's post-turn hook has moved"
        )
        XCTAssertTrue(
            code.contains("guard callLoop.brain.servesOneCacheSlot else { return }"),
            """
            the call anchors the prompt cache without a tier guard. Calls are \
            hosted-only, so this is a paid request after every single spoken \
            turn for a checkpoint the provider has no slot to hold.
            """
        )
    }

    /// A call cannot be held by the one tier worth anchoring, which is why the
    /// guard above makes that closure a no-op today. Stated so nobody deletes it
    /// as dead code without reading why it is dead.
    func testTheTierThatCanHoldACallIsNotTheTierWorthAnchoring() {
        XCTAssertTrue(BrainCapabilities.hosted.holdsARealtimeCall)
        XCTAssertFalse(BrainCapabilities.hosted.servesOneCacheSlot)
        XCTAssertFalse(BrainCapabilities.onDevice.holdsARealtimeCall)
        XCTAssertTrue(BrainCapabilities.onDevice.servesOneCacheSlot)
    }

    /// **That `complete` actually uses it.**
    ///
    /// Every test above calls `cachedSystemBlocks` directly, so deleting the one
    /// line in `complete` that assigns it to `body["system"]` left the whole
    /// file green — the switch could be turned back off with the suite passing.
    /// Found by the 1.7.2 re-audit, and it was right: the helper is not the
    /// feature, the assignment is.
    ///
    /// A source check because `complete` needs a live URLSession and a
    /// credential. Narrow: it asserts the assignment, not the shape of the file.
    func testCompleteActuallyPutsTheCachedBlocksOnTheRequest() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/Brain/AnthropicBackend.swift"),
            encoding: .utf8
        )
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)

        XCTAssertTrue(
            code.contains("body[\"system\"] = Self.cachedSystemBlocks(systemText)"),
            """
            the request no longer carries the cached system blocks, so caching is \
            off and every hosted turn re-reads the catalogue and system prompt at \
            full price — with these tests still green, because they call the \
            helper rather than the encoder
            """
        )
        // And the tools must still be assigned ahead of it, or the prefix drops
        // under Haiku's 4,096-token minimum and silently never caches.
        let toolsAt = code.range(of: "body[\"tools\"]")?.lowerBound
        let systemAt = code.range(of: "body[\"system\"] = Self.cachedSystemBlocks")?.lowerBound
        guard let toolsAt, let systemAt else { return XCTFail("could not find both assignments") }
        XCTAssertLessThan(
            toolsAt, systemAt,
            "tools must be assigned before system so the cached prefix clears the 4,096-token minimum"
        )
    }

    // MARK: The warm-up that must not run

    /// **A hosted brain has no slot to protect, and was being charged to have
    /// one protected.**
    ///
    /// `anchorPromptCache` replays the conversation to plant a llama.cpp KV
    /// checkpoint — every word of its justification is about qwen3.5's hybrid
    /// attention and Ollama's single slot. On a hosted provider the cache is
    /// server-side and prefix-keyed: there is nothing to plant and nothing to
    /// evict, so it was a second paid API request on every single turn.
    ///
    /// `servesOneCacheSlot` exists to answer exactly this and already gated the
    /// keep-warm timer and the window's copy. The daemon's per-turn call site
    /// was never given the same line.
    func testOnlyABrainWithOneSlotIsWorthAnchoring() {
        XCTAssertTrue(
            BrainCapabilities.onDevice.servesOneCacheSlot,
            "a local model is exactly what the checkpoint replay was written for"
        )
        XCTAssertFalse(
            BrainCapabilities.hosted.servesOneCacheSlot,
            "anchoring a hosted brain buys nothing and costs a request per turn"
        )
    }

    /// That the daemon actually asks.
    ///
    /// A source check because `VoiceBridgeDaemon` needs a live `SignalClient` —
    /// a concrete actor that shells out to `signal-cli` — so it cannot be built
    /// in a test. Narrow: it asserts the guard sits on the anchoring call, not
    /// the shape of the file.
    func testTheDaemonDoesNotAnchorAHostedBrain() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/SageVoiceCore/VoiceBridgeDaemon.swift"),
            encoding: .utf8
        )
        let scan = SwiftSourceScan(source)
        let code = scan.text(in: 0..<scan.characters.count)

        XCTAssertTrue(
            code.contains("if loop.brain.servesOneCacheSlot {"),
            """
            the per-turn prompt-cache anchor is not gated by tier, so a hosted \
            key pays for an extra request after every message that plants a \
            checkpoint the provider does not have
            """
        )
        // The field is still set unconditionally: it means "the thread spoken
        // to last", which `recentMessagesForCall` reads to open a call on the
        // right conversation. Gating that too would have opened calls on an
        // arbitrary thread.
        XCTAssertTrue(
            code.contains("lastAnchoredKey = key"),
            "the last-spoken-to thread is no longer recorded, so a call opens on whichever thread comes first"
        )
    }
}
