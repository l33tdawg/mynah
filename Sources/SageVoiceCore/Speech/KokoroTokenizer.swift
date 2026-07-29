import Foundation

/// Turns a phoneme string into the token sequence Kokoro's ONNX graph expects.
///
/// ## Where this table came from
///
/// Not from a specification — there isn't one. It was read out of the running
/// `kokoro_onnx` 0.5.0 on this Mac and checked against the tokens that package
/// actually fed the model for two known sentences. That matters because a
/// vocabulary is exactly the kind of thing that fails silently: a wrong id does
/// not crash, it produces a different phoneme, and the result is speech that is
/// subtly and unaccountably wrong.
///
/// The ids are sparse and the gaps are real — 26, 28, 30, 32 and others are
/// absent, and the table is copied as found rather than tidied. A tidied table
/// would be a different table.
///
/// ## What is deliberately not here
///
/// No grapheme-to-phoneme. That is espeak-ng's job, it is GPLv3, and it runs as
/// a separate process for exactly that reason — see `KokoroPhonemizer`. This
/// type starts from the IPA string espeak produced.
public enum KokoroTokenizer {

    /// The padding token, used at both ends of every sequence.
    public static let padding: Int64 = 0

    /// The model's positional embedding is 510 long, and the style vector is
    /// selected by token count from an array of the same size — so a sequence
    /// longer than this has nowhere to index. `kokoro_onnx` splits the phoneme
    /// string into batches before it gets here.
    public static let maximumTokens = 510

    /// Phoneme character to token id, as `kokoro_onnx.tokenizer` holds it.
    public static let vocabulary: [Character: Int64] = [
        ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6, "—": 9, "…": 10,
        "\"": 11, "(": 12, ")": 13, "“": 14, "”": 15, " ": 16,
        "\u{0303}": 17, "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22, "ꭧ": 23,
        "A": 24, "I": 25, "O": 31, "Q": 33, "S": 35, "T": 36, "W": 39, "Y": 41,
        "ᵊ": 42, "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48,
        "h": 50, "i": 51, "j": 52, "k": 53, "l": 54, "m": 55, "n": 56,
        "o": 57, "p": 58, "q": 59, "r": 60, "s": 61, "t": 62, "u": 63,
        "v": 64, "w": 65, "x": 66, "y": 67, "z": 68,
        "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72, "β": 75, "ɔ": 76, "ɕ": 77, "ç": 78,
        "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83, "ɚ": 85, "ɛ": 86, "ɜ": 87,
        "ɟ": 90, "ɡ": 92, "ɥ": 99, "ɨ": 101, "ɪ": 102, "ʝ": 103,
        "ɯ": 110, "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115,
        "ø": 116, "ɸ": 118, "θ": 119, "œ": 120, "ɹ": 123, "ɾ": 125, "ɻ": 126,
        "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132, "ʧ": 133,
        "ʊ": 135, "ʋ": 136, "ʌ": 138, "ɣ": 139, "ɤ": 140, "χ": 142, "ʎ": 143,
        "ʒ": 147, "ʔ": 148, "ˈ": 156, "ˌ": 157, "ː": 158, "ʰ": 162, "ʲ": 164,
        "↓": 169, "→": 171, "↗": 172, "↘": 173, "ᵻ": 177
    ]

    /// The ids for a phoneme string, **without** the padding at either end.
    ///
    /// Characters outside the vocabulary are dropped rather than substituted.
    /// That is what `kokoro_onnx` does, and the alternative — mapping the unknown
    /// to some nearby sound — would put a phoneme in the owner's speech that
    /// nothing in the text asked for.
    public static func ids(for phonemes: String) -> [Int64] {
        phonemes.compactMap { vocabulary[$0] }
    }

    /// The full sequence fed to the graph: a pad, the phonemes, a pad.
    ///
    /// The model was trained with those bracketing zeros and produces noticeably
    /// worse audio without them — they are not a formality.
    public static func tokens(for phonemes: String) -> [Int64] {
        [padding] + ids(for: phonemes) + [padding]
    }

    /// Whether a phoneme string fits in one pass.
    ///
    /// Measured on the **unpadded** count, because that is what indexes the
    /// style vector — see `KokoroVoices`.
    public static func fits(_ phonemes: String) -> Bool {
        ids(for: phonemes).count <= maximumTokens
    }
}
