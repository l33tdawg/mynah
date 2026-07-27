import XCTest
@testable import SageVoiceCore

/// Guards the byte-stability of request bodies.
///
/// These are latency tests. Nothing here can fail in a way that breaks a reply —
/// which is exactly why they exist. When key ordering drifted, every prompt cache
/// in the stack silently missed, the appliance re-prefilled 3,572 tokens per turn
/// at 16.4 s, and not one test went red.
final class PromptStableJSONTests: XCTestCase {

    /// The top level must be ordered.
    func testTopLevelKeysAreSorted() throws {
        let body: [String: Any] = ["model": "qwen3.5:4b", "stream": false, "думать": 1, "apple": 2]
        let text = String(decoding: try PromptStableJSON.data(from: body), as: UTF8.self)

        let keyOrder = ["\"apple\"", "\"model\"", "\"stream\""].map {
            text.range(of: $0).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? -1
        }
        XCTAssertFalse(keyOrder.contains(-1), "expected every key present in \(text)")
        XCTAssertEqual(keyOrder, keyOrder.sorted(), "top-level keys must serialise in ascending order")
    }

    /// The one that actually mattered.
    ///
    /// The unstable ordering was *inside* the tool schemas — nested two and three
    /// levels down in `inputSchema` — not at the top level of the request. A
    /// sort that did not recurse would have left the bug exactly where it was
    /// while looking like a fix.
    func testNestedObjectKeysAreSortedAtEveryDepth() throws {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "zeta": ["type": "string", "description": "last"],
                "alpha": ["type": "string", "description": "first"]
            ]
        ]
        let text = String(decoding: try PromptStableJSON.data(from: ["tools": [schema]]), as: UTF8.self)

        guard let alpha = text.range(of: "\"alpha\""), let zeta = text.range(of: "\"zeta\"") else {
            return XCTFail("expected both nested keys in \(text)")
        }
        XCTAssertLessThan(alpha.lowerBound, zeta.lowerBound, "nested keys must sort too, not just the top level")

        // And within a nested object: "description" precedes "type".
        guard let description = text.range(of: "\"description\""), let type = text.range(of: "\"type\":\"string\"") else {
            return XCTFail("expected nested object keys in \(text)")
        }
        XCTAssertLessThan(description.lowerBound, type.lowerBound)
    }

    /// Two dictionaries built in a different insertion order are the same prompt,
    /// and must produce the same bytes — because a prefix cache compares bytes,
    /// not meaning.
    func testDifferentInsertionOrderProducesIdenticalBytes() throws {
        var forward: [String: Any] = [:]
        forward["alpha"] = 1
        forward["beta"] = 2
        forward["gamma"] = 3

        var backward: [String: Any] = [:]
        backward["gamma"] = 3
        backward["beta"] = 2
        backward["alpha"] = 1

        XCTAssertEqual(
            try PromptStableJSON.data(from: forward),
            try PromptStableJSON.data(from: backward),
            "the same prompt must serialise to the same bytes however the dictionary was built"
        )
    }
}
