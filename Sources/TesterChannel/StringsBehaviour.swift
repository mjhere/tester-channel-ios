import Foundation

/// The two things about the panel's words that are behaviour rather than data.
///
/// The words themselves — the English defaults, the key-to-property map and the
/// languages this client ships — are generated from the web client into
/// `Generated/Strings.swift`, because `sdk/web/tester-channel.js` is the
/// authority for what a word is and hand-typing a second copy of 28 of them is
/// how `removedNotice` reached a shipped client on a key the service refuses.
///
/// Not called `Strings.swift`, which is what it was until the first time Xcode
/// saw it: a target may not hold two files with the same name, whatever folder
/// they sit in. The generated one keeps the name, because the generator, its
/// test and CLAUDE.md all spell it.

public extension PanelStrings {
    /// `{max}` and `{name}` in a string, filled in.
    ///
    /// Placeholders rather than a value glued onto the end of a sentence,
    /// because word order is the first thing that differs between languages.
    /// Only the tokens handed in are touched; anything else in braces is left
    /// exactly as the customer typed it.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                return out
            }
            let key = String(rest[rest.index(after: open)..<close])
            out += values[key] ?? "{\(key)}"
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}

/// Which available locale to use for somebody who wanted `wanted`.
///
/// Mirrors `matchLocale` in `src/locale.ts` and the one in the web client. RFC
/// 4647 lookup with its one oddity — a single-character subtag starts an
/// extension, so `de-DE-u-co-phonebk` must not be truncated to `de-DE-u`, which
/// names nothing — plus the widening rule lookup does not have: somebody asking
/// for `cs` where the only translation is `cs-CZ` gets it. Strictly a miss, and
/// strictly the wrong answer: an operator who translated their app into Czech
/// translated it into Czech, and the gap between the tag they chose and the one
/// a phone reports is not theirs to know about.
enum LocaleMatch {
    static func best(available: [String], wanted: String?) -> String? {
        guard let wanted = wanted?.trimmed, !wanted.isEmpty, !available.isEmpty else { return nil }

        // Ordered, first spelling of a tag winning. A Dictionary would do for
        // the lookup pass and not for the widening one: that answers with the
        // *first* match, so the order `available` arrived in is part of the
        // answer, and the other two implementations iterate a Map in insertion
        // order. Sorting instead made this the one of the three that picked
        // `de-AT` where they picked `de-CH`.
        var seen = Set<String>()
        var have: [(lower: String, original: String)] = []
        for tag in available where seen.insert(tag.lowercased()).inserted {
            have.append((tag.lowercased(), tag))
        }

        let asked = wanted.lowercased()
        for step in chain(asked) {
            if let hit = have.first(where: { $0.lower == step }) { return hit.original }
        }

        // Widening stops at a private-use subtag, and the joke language is what
        // found it. `art` is the collective code for artificial languages, so
        // `art-x-huttese` and `art-x-klingon` share a primary subtag and are not
        // variants of one language — the whole of what they name is after the
        // `x`. Widening across that would answer a request for one with the
        // other, which is the one case where "a variant of the language asked
        // for" stops being true. Until this client shipped a bundled pack the
        // rule cost nothing here, because `art-x-huttese` was never among the
        // tags to widen to; it is now.
        if isPrivateUse(asked) { return nil }
        guard let language = asked.split(separator: "-").first.map(String.init) else { return nil }
        for entry in have
        where !isPrivateUse(entry.lower)
            && entry.lower.split(separator: "-").first.map(String.init) == language {
            return entry.original
        }
        return nil
    }

    /// `art-x-huttese` — a tag whose meaning lives entirely in its private-use subtag.
    static func isPrivateUse(_ tag: String) -> Bool {
        tag.split(separator: "-").contains("x")
    }

    /// `zh-Hant-TW`, `zh-Hant`, `zh` — most specific first.
    static func chain(_ tag: String) -> [String] {
        let parts = tag.split(separator: "-").map(String.init)
        var out: [String] = []
        var n = parts.count
        while n > 0 {
            defer { n -= 1 }
            if n > 1 && parts[n - 1].count == 1 { continue }
            out.append(parts[0..<n].joined(separator: "-"))
        }
        return out
    }
}
