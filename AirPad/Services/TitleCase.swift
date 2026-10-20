import Foundation

/// live-28 (A3) — Title Case for MODEL-written titles (entry titles, chat titles, document names proposed from text),
/// applied in code right after the model returns — never by prompting. Never for a title the user typed, B1's
/// first-words fallback (the user's own words), or summaries (sentence case). Chicago-style:
/// - every word capitalized, except a, an, the, and, but, or, nor, for, so, yet, as, at, by, in, of, on, per, to, via,
///   vs. — lowercase unless first, last, or right after a colon (live-29 (3): up / off / out / down / over are mostly
///   phrasal-verb particles in titles — "Setting Up", "Turning Off" — so they're capitalized);
/// - a word that already has an inner capital or is all caps stays as it is (iPhone, AirPad, NFC, BBQ, macOS);
/// - a hyphenated compound capitalizes its first part and every later part except the minor words, which stay
///   lowercase inside it ("Long-Term", "Self-Driving", "State-of-the-Art", "Mother-in-Law") — live-29 (3), Chicago;
/// - only the first letter changes: the rest of a word is left as written.
enum TitleCase {
    static let minorWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at",
                                          "by", "in", "of", "on", "per", "to", "via", "vs.", "vs"]

    static func apply(_ title: String) -> String {
        let words = title.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let real = words.indices.filter { words[$0].contains { $0.isLetter || $0.isNumber } }
        guard let first = real.first, let last = real.last else { return title }
        var out = words, afterColon = false
        for i in words.indices {
            let w = words[i]
            if real.contains(i) {
                let opens = w.first.map { "(\"“‘[".contains($0) } ?? false   // "(a field guide)" → "(A"
                out[i] = word(w, forceCap: i == first || i == last || afterColon || opens)
            }
            if !w.isEmpty { afterColon = w.hasSuffix(":") }
        }
        return out.joined(separator: " ")
    }

    private static func word(_ w: String, forceCap: Bool) -> String {
        if w.dropFirst().contains("-") {
            let parts = w.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            return parts.enumerated().map { i, p in
                if i == 0 { return capitalized(p) }
                if keepsCase(p) { return p }
                let core = p.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
                return minorWords.contains(core) ? p.lowercased() : capitalized(p)
            }.joined(separator: "-")
        }
        if keepsCase(w) { return w }
        let core = w.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted.subtracting(CharacterSet(charactersIn: ".")))
        if !forceCap, minorWords.contains(core) || minorWords.contains(core.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            return w.lowercased()
        }
        return capitalized(w)
    }

    /// Inner capitals or all caps: the writer's casing (iPhone, macOS, NFC, BBQ).
    private static func keepsCase(_ w: String) -> Bool {
        let letters = w.filter(\.isLetter)
        return (letters.count >= 2 && letters.allSatisfy(\.isUppercase)) || letters.dropFirst().contains(where: \.isUppercase)
    }

    private static func capitalized(_ w: String) -> String {
        if keepsCase(w) { return w }
        guard let i = w.firstIndex(where: \.isLetter) else { return w }
        return w.replacingCharacters(in: i...i, with: String(w[i]).uppercased())
    }
}

#if DEBUG
/// `-TitleCaseSelfTest` — ~30 synthetic titles through `TitleCase.apply`.
enum TitleCaseSelfTest {
    static let cases: [(String, String)] = [
        ("the art of slow coffee", "The Art of Slow Coffee"),
        ("notes on a morning walk", "Notes on a Morning Walk"),
        ("what it comes down to", "What It Comes Down To"),
        ("a quiet place to think", "A Quiet Place to Think"),
        ("coffee: a love story", "Coffee: A Love Story"),
        ("the long-term plan", "The Long-Term Plan"),
        ("setting up my new iPhone", "Setting Up My New iPhone"),   // live-29 (3): "up" is a particle — capitalized
        ("AirPad launch checklist", "AirPad Launch Checklist"),
        ("NFC tags for the kitchen", "NFC Tags for the Kitchen"),
        ("weekend BBQ menu", "Weekend BBQ Menu"),
        ("upgrading to macOS 27", "Upgrading to macOS 27"),
        ("cats vs. dogs debate", "Cats vs. Dogs Debate"),
        ("travel via the old road", "Travel via the Old Road"),
        ("bread and butter pickles", "Bread and Butter Pickles"),
        ("in the garden at dusk", "In the Garden at Dusk"),
        ("a walk in the park", "A Walk in the Park"),
        ("first-time sourdough", "First-Time Sourdough"),
        ("the end of the road", "The End of the Road"),
        ("things to look out for", "Things to Look Out For"),
        ("café notes from lisbon", "Café Notes From Lisbon"),
        ("don't forget the keys", "Don't Forget the Keys"),
        ("two cups per day", "Two Cups per Day"),
        ("rain, wind and the tide", "Rain, Wind and the Tide"),
        ("The Old Man And The Sea", "The Old Man and the Sea"),
        ("tide pools (a field guide)", "Tide Pools (A Field Guide)"),
        ("“the last good summer”", "“The Last Good Summer”"),
        ("3D printing a lamp", "3D Printing a Lamp"),
        ("on writing", "On Writing"),
        ("off the grid", "Off the Grid"),
        ("Already Title Cased", "Already Title Cased"),
        // live-29 (3) — inside a hyphenated compound the minor words stay lowercase (Companion's live-28 spec said
        // "capitalize every part"; Chicago doesn't); the first part is always capitalized.
        ("state-of-the-art tools", "State-of-the-Art Tools"),
        ("self-driving cars", "Self-Driving Cars"),
        ("mother-in-law visit", "Mother-in-Law Visit"),
        ("up-to-date notes", "Up-to-Date Notes"),
        ("notes on an up-to-date plan", "Notes on an Up-to-Date Plan"),
        ("a bring-your-own-device policy", "A Bring-Your-Own-Device Policy"),
        ("backing up photos over wi-fi", "Backing Up Photos Over Wi-Fi"),
        // live-29 (3) — up / off / out / down / over are mostly phrasal-verb particles in titles: capitalized.
        ("turning off the lights", "Turning Off the Lights"),
        ("figuring out the budget", "Figuring Out the Budget"),
        ("winding down for the night", "Winding Down for the Night"),
        ("taking over the garden", "Taking Over the Garden"),
        ("cleaning up after the move", "Cleaning Up After the Move"),
        ("", ""),
    ]

    static func run() -> String {
        var fails: [String] = []
        for (input, want) in cases {
            let got = TitleCase.apply(input)
            if got != want { fails.append("  FAIL  \"\(input)\" → \"\(got)\" (want \"\(want)\")") }
        }
        let pass = cases.count - fails.count
        return "\(fails.isEmpty ? "PASS" : "FAIL") — \(pass)/\(cases.count)" + (fails.isEmpty ? "" : "\n" + fails.joined(separator: "\n"))
    }
}
#endif
