import Foundation

/// Reading a Swift file the way a guard has to read one.
///
/// **Written because four guards in this suite read source with
/// `line.range(of: "//")` and a fixed byte window, and every one of them could
/// be fooled by an ordinary line of code.** The two failures, both found on 4
/// August 2026 while repairing them:
///
/// - `NoTimerRacedInATaskGroupTests.code(in:)` cut each line at its first `//`
///   with no idea what a string literal is. A single `"https://example.com"`
///   inside a task group deleted the rest of that line — including its closing
///   brace — so the brace matcher below it ran off, and the group's body came
///   back as one character. A guard that reads one character of a body finds
///   nothing in it, and reports success.
/// - `MemoryOwnedScopeTests` originally looked 400 characters either side of a
///   call for the argument it wanted, and found the *neighbouring* branch's
///   argument. Spans here are matched by bracket depth for that reason, never
///   by distance.
///
/// So this scans once, character by character, and records for every character
/// whether it is inside a comment and whether it is inside a string literal.
/// Everything else — searching, bracket matching, finding the block a call sits
/// in — is answered from those two arrays, which means a `//` in a URL, a brace
/// in a JSON literal and a `/* */` around a whole function all behave the way
/// the compiler treats them rather than the way a regular expression guesses.
///
/// Indices are `Int` offsets into `characters`, deliberately. `String.Index`
/// values are not portable between two `String`s, and every one of these guards
/// wants to search one derived view (comments blanked) and then bracket-match in
/// another (comments *and* literals blanked).
struct SwiftSourceScan {

    /// The file, exactly as it was on disk.
    let characters: [Character]

    /// True where the character is part of a `//` or `/* */` comment.
    private let commented: [Bool]

    /// True where the character is part of a string literal, quotes included.
    ///
    /// Interpolation is deliberately counted as literal. A `\(items.map { $0 })`
    /// carries braces that balance inside the literal, so ignoring them entirely
    /// is safe, whereas counting them would depend on the interpolation being
    /// well-formed in a file that may be mid-edit.
    private let quoted: [Bool]

    init(_ source: String) {
        var characters = Array(source)
        var commented = [Bool](repeating: false, count: characters.count)
        var quoted = [Bool](repeating: false, count: characters.count)

        func peek(_ index: Int) -> Character? {
            index < characters.count ? characters[index] : nil
        }

        /// Marks a string literal starting at `start` and answers the index just
        /// past it. Handles the three shapes that appear in this repository:
        /// `"a"`, `"""a"""`, and the raw `#"a"#` form the JSON fixtures use.
        func markString(from start: Int) -> Int {
            var index = start
            var pounds = 0
            while peek(index) == "#" {
                quoted[index] = true
                pounds += 1
                index += 1
            }
            let isMultiline = peek(index) == "\"" && peek(index + 1) == "\"" && peek(index + 2) == "\""
            let quotes = isMultiline ? 3 : 1
            for _ in 0..<quotes {
                if index < characters.count { quoted[index] = true }
                index += 1
            }
            while index < characters.count {
                let character = characters[index]
                // A raw string's escape carries the same number of pounds it was
                // opened with, so `\#n` escapes in `#"…"#` and a bare backslash
                // does not.
                if character == "\\" {
                    var escape = index + 1
                    var seen = 0
                    while seen < pounds, peek(escape) == "#" {
                        escape += 1
                        seen += 1
                    }
                    if seen == pounds {
                        for mark in index...min(escape, characters.count - 1) { quoted[mark] = true }
                        index = escape + 1
                        continue
                    }
                }
                // An unterminated single-quoted literal must not swallow the
                // rest of the file. Swift does not allow one, but a file being
                // edited in another window is not always valid Swift.
                if character == "\n", !isMultiline {
                    return index
                }
                if character == "\"" {
                    var end = index
                    var closing = 0
                    while closing < quotes, peek(end) == "\"" {
                        end += 1
                        closing += 1
                    }
                    var seen = 0
                    while seen < pounds, peek(end) == "#" {
                        end += 1
                        seen += 1
                    }
                    if closing == quotes, seen == pounds {
                        for mark in index..<min(end, characters.count) { quoted[mark] = true }
                        return end
                    }
                }
                quoted[index] = true
                index += 1
            }
            return index
        }

        var index = 0
        var blockDepth = 0
        while index < characters.count {
            let character = characters[index]
            if blockDepth > 0 {
                commented[index] = true
                if character == "/", peek(index + 1) == "*" {
                    commented[index + 1] = true
                    blockDepth += 1
                    index += 2
                    continue
                }
                if character == "*", peek(index + 1) == "/" {
                    commented[index + 1] = true
                    blockDepth -= 1
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if character == "/", peek(index + 1) == "/" {
                while index < characters.count, characters[index] != "\n" {
                    commented[index] = true
                    index += 1
                }
                continue
            }
            if character == "/", peek(index + 1) == "*" {
                commented[index] = true
                commented[index + 1] = true
                blockDepth = 1
                index += 2
                continue
            }
            if character == "\"" {
                index = markString(from: index)
                continue
            }
            if character == "#" {
                // `#filePath`, `#if` and friends are not literals; only a run of
                // pounds followed by a quote opens a raw string.
                var ahead = index
                while peek(ahead) == "#" { ahead += 1 }
                if peek(ahead) == "\"" {
                    index = markString(from: index)
                    continue
                }
                index += 1
                continue
            }
            index += 1
        }

        // Blanked rather than deleted, so every index below lines up with the
        // file on disk and a reported line number is the one an engineer can
        // open. Newlines survive for the same reason.
        for position in characters.indices where commented[position] && characters[position] != "\n" {
            characters[position] = " "
        }

        self.characters = characters
        self.commented = commented
        self.quoted = quoted
    }

    // MARK: Searching

    /// Every index where `needle` appears in code — comments excluded, string
    /// literals kept.
    ///
    /// Literals are kept because the thing most of these guards look for *is* a
    /// literal: `"sage_task"`, `"sage_list"`. Stripping them would leave nothing
    /// to find.
    func indices(of needle: String) -> [Int] {
        let pattern = Array(needle)
        guard !pattern.isEmpty, characters.count >= pattern.count else { return [] }
        var hits: [Int] = []
        for start in 0...(characters.count - pattern.count) {
            if commented[start] { continue }
            var offset = 0
            while offset < pattern.count, characters[start + offset] == pattern[offset] {
                offset += 1
            }
            if offset == pattern.count { hits.append(start) }
        }
        return hits
    }

    func contains(_ needle: String) -> Bool { !indices(of: needle).isEmpty }

    /// The code text of a range, for putting in a failure message.
    func text(in range: Range<Int>) -> String {
        String(characters[range.clamped(to: 0..<characters.count)])
    }

    /// One-based, so it can be pasted after a colon and opened.
    func line(of index: Int) -> Int {
        1 + characters[0..<min(index, characters.count)].filter { $0 == "\n" }.count
    }

    /// The single line an index sits on, trimmed — enough to recognise a site in
    /// a failure message without printing a screenful.
    func statement(at index: Int) -> String {
        var start = index
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        var end = index
        while end < characters.count, characters[end] != "\n" { end += 1 }
        return String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Bracket matching

    /// Whether this character counts when brackets are being balanced.
    ///
    /// A brace inside a comment or a string literal is not a brace. This is the
    /// whole reason the two arrays exist.
    private func isStructural(_ index: Int) -> Bool {
        !commented[index] && !quoted[index]
    }

    /// The span of the bracketed block that opens at or after `from`, including
    /// both brackets.
    ///
    /// Matched by depth. Never by distance — see the note at the top of this
    /// file about the 400-character window that read the neighbouring branch.
    func block(from index: Int, open: Character = "{", close: Character = "}") -> Range<Int>? {
        var start = index
        while start < characters.count, !(isStructural(start) && characters[start] == open) {
            start += 1
        }
        guard start < characters.count else { return nil }
        var depth = 0
        var position = start
        while position < characters.count {
            if isStructural(position) {
                if characters[position] == open { depth += 1 }
                if characters[position] == close {
                    depth -= 1
                    if depth == 0 { return start..<(position + 1) }
                }
            }
            position += 1
        }
        return nil
    }

    /// The innermost `{ … }` containing `index`, or `nil` at file scope.
    func enclosingBlock(of index: Int) -> Range<Int>? {
        var open: [Int] = []
        var position = 0
        while position < index, position < characters.count {
            if isStructural(position) {
                if characters[position] == "{" { open.append(position) }
                if characters[position] == "}" { _ = open.popLast() }
            }
            position += 1
        }
        guard let innermost = open.last else { return nil }
        return block(from: innermost)
    }

    /// The argument list of the call whose name ends at `index`, brackets
    /// included: `foo(a, b)` scanned from the `f` gives `(a, b)`.
    func arguments(from index: Int) -> Range<Int>? {
        block(from: index, open: "(", close: ")")
    }

    /// The identifier immediately before `index`, which for an index pointing at
    /// a `.method(` is the thing the method was called on.
    ///
    /// The last component only: `self.loop.run(` answers `loop`, which is the
    /// name a declaration can be found for.
    func receiver(before index: Int) -> String {
        var cursor = index - 1
        var name: [Character] = []
        while cursor >= 0, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
            name.append(characters[cursor])
            cursor -= 1
        }
        return String(name.reversed())
    }

    /// The identifier bound by the nearest `let`/`var` at or before `index`.
    ///
    /// Used to follow a turn's result to whatever inspects it. The declaration
    /// is often a line above the call — `let result = try await withDeadline(…) {
    /// try await brain.run(…) }` — so the binding cannot be read off the call's
    /// own line.
    func bindingBefore(_ index: Int) -> (name: String, index: Int)? {
        var best: (name: String, index: Int)?
        for keyword in ["let ", "var "] {
            for start in indices(of: keyword) where start < index {
                var cursor = start + keyword.count
                while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
                var name = ""
                while cursor < characters.count,
                      characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" {
                    name.append(characters[cursor])
                    cursor += 1
                }
                guard !name.isEmpty else { continue }
                if best == nil || start > best!.index { best = (name, start) }
            }
        }
        return best
    }
}
