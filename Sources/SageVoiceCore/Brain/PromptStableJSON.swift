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
    ///
    /// Checked before encoding, because `JSONSerialization` does not report an
    /// unencodable object by throwing a Swift error — it raises an Objective-C
    /// exception, which `try` cannot catch and which terminates the process.
    /// Every call site here is wrapped in a `do/catch` that reads as though it
    /// handles this and does not.
    ///
    /// It cost a crash: the Ollama pull request was built with `JSONValue`
    /// rather than Foundation values, and the app aborted the moment anybody
    /// chose to run the model on their own Mac. A mistake of that shape should
    /// surface as a failed request, which the setup screen can explain, not as
    /// the application disappearing.
    static func data(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Failure.notEncodable(String(describing: type(of: object)))
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    enum Failure: Error, CustomStringConvertible {
        case notEncodable(String)

        var description: String {
            switch self {
            case .notEncodable(let type):
                return "a request body of type \(type) cannot be encoded as JSON; "
                    + "it must be built from Foundation values, not Swift enums"
            }
        }
    }
}
