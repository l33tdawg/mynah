import Foundation

/// Which models on this machine can actually look at a photo.
///
/// **This exists because `OllamaBackend.seesImages` was a hardcoded `true`, and
/// that constant answered the wrong question.**
///
/// Its comment defended itself narrowly and honestly: *"the request built here
/// carries the bytes (`object["images"]`), so a vision model receives them"* —
/// which is true of the request and says nothing about the model. The appliance
/// ships `qwen3.5:4b`, which has no visual encoder at all. So the arrival note
/// put *"You can see it — say what it is, specifically"* into the prompt of a
/// model with no eyes, and called the model's *"I can't see one"* an honest
/// answer. That is a hope, not a mechanism, and the instruction actively pressed
/// the model the other way. `seesImages` was a per-backend constant answering a
/// per-model question.
///
/// ## Why families, not exact ids
///
/// `CloudBrainModelCatalog` matches hosted ids exactly, because a hosted id is
/// a fixed string the vendor publishes. Local ids are not: Ollama names carry a
/// tag (`llava:13b`, `qwen2.5vl:7b-q4_K_M`, `minicpm-v:8b-2.6-q8_0`) and an
/// LM Studio name carries a quantisation and a build (`llava-v1.6-mistral-7b`).
/// An exact table would have to enumerate every tag anyone might pull, which is
/// unbounded, so it would be wrong for almost every owner — in the direction
/// that says "not looked at" when it could have looked. Families are the unit
/// the owner actually chooses.
///
/// ## What is deliberately NOT here
///
/// **Families whose vision depends on the size tag.** `gemma3:1b` is text-only
/// and `gemma3:4b` is not; `mistral-small3` has the same shape. A family match
/// on those would claim sight for the small variant, which is the fabrication
/// direction — so they stay out and their owners are told plainly that the
/// picture was not looked at.
///
/// ## Every dead end needs a door
///
/// This table is a stand-in for a probe that already exists. Ollama's
/// `/api/show` reports `capabilities: ["completion","vision"]` per model, which
/// answers the question for every family and every tag without anybody
/// maintaining a list. The way this type retires is that `availability()` asks
/// once and caches the answer, and `sees(_:)` becomes the fallback for the
/// window before that reply lands — not by growing the list on hunches.
public enum LocalVisionModels {

    /// Model families documented to accept images, matched on the name before
    /// the tag.
    ///
    /// Ordinary vision families rather than anything exotic: these are the ones
    /// an owner who wants a local model that can see is actually told to pull.
    static let sightedFamilies = [
        "llava",
        "bakllava",
        "llama3.2-vision",
        "llama3.1-vision",
        "qwen2.5vl",
        "qwen2-vl",
        "minicpm-v",
        "moondream",
        "granite3.2-vision"
    ]

    /// Whether a local model name belongs to a family that reads pictures.
    ///
    /// The name is lowercased and cut at the first `:` — Ollama's tag separator
    /// — then matched as a prefix, which is what makes one entry cover both
    /// `llava:13b` (Ollama) and `llava-v1.6-mistral-7b` (LM Studio) without the
    /// table knowing which server it is talking to.
    ///
    /// A prefix rather than a contains: `contains` would match a model merely
    /// *mentioning* a family in a fine-tune suffix, and inheriting a claim of
    /// sight from a substring is exactly the guess this file refuses to make.
    public static func sees(_ model: String) -> Bool {
        let name = model
            .lowercased()
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        guard !name.isEmpty else { return false }
        return sightedFamilies.contains { name.hasPrefix($0) }
    }
}
