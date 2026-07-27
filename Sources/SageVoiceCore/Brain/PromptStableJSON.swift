import Foundation

/// Serialises a request body so that identical prompts produce identical bytes.
///
/// Every prompt cache worth having — llama.cpp's prefix cache, Anthropic's
/// `cache_control`, DeepSeek's context cache — matches on a *byte* prefix. None
/// of them parse the JSON first. So two requests that are semantically the same
/// but serialise their keys in a different order are, to a cache, two unrelated
/// prompts.
///
/// That is not a hypothetical. Tool schemas here are `[String: JSONValue]`, and
/// Swift seeds dictionary hashing per process, so the same 14 SAGE tools came
/// out with their JSON keys in a different order on every run. Those schemas sit
/// at the front of the prompt, ahead of the owner's words, so the prompt changed
/// from roughly its first token every single time. Measured on the M2 appliance:
///
///     unsorted   prompt eval 3,572 tokens / 16.4 s   →  turn 27.7 s
///     sorted     prompt eval     4 tokens /  0.12 s  →  turn 11.0 s
///
/// A 2.6× speedup from sorting keys. `.sortedKeys` recurses, which is the part
/// that matters — the instability was inside the nested schema objects, not at
/// the top level.
///
/// This exists as one function rather than three call sites because the failure
/// is invisible: nothing errors, no test goes red, the appliance just gets
/// slower and every provider silently charges full price for a cache miss.
enum PromptStableJSON {

    /// The request body, with every object's keys in ascending order at every
    /// depth.
    static func data(from object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
