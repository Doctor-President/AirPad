// Sweep 2b · 3.3 — the iPhone spike's fixed inputs: invented passages, the probe's latency jobs, the 12-case
// mini-suite and its code grader, the sensitive-topic notes for Q4, and the ten-turn questions for Q5.
// ONE file, compiled verbatim into the phone app (Spike2b) and the Mac runner (spike-mac), so both run the same
// prompts. Every passage is INVENTED; nothing here comes from T's library.
//
// The @Generable types, passages P1–P12, the sort questions, the four latency questions and every instruction marked
// "probe" are copied verbatim from scripts/librarian/apple_call_probe.swift, so the latency numbers compare with
// design.md §14.
import Foundation
import FoundationModels

// MARK: - Generable types (verbatim from the probe)

@Generable enum QuestionKind { case library, generalKnowledge, web, aboutTheAssistant, chitChat }

@Generable struct Sorted {
    @Guide(description: "What the question needs: the user's own notes, general knowledge, a web search, a fact about this assistant, or just conversation.")
    var kind: QuestionKind
}

@Generable struct Pick {
    @Guide(description: "The number of the one passage that answers the question, or 0 if none does.")
    var passage: Int
    @Guide(description: "One sentence copied word for word from that passage that answers the question. Empty if none.")
    var sentence: String
}

// MARK: - Passages

enum SpikeData {
    /// P1–P12: the probe's passages, verbatim and in the probe's order (packet(n) = the first n).
    static let probePassages: [String] = [
        "The greenhouse heater is on the timer by the door. It comes on at six in the evening from October to March. The spare fuse is taped inside the lid of the grey toolbox.",
        "Marta's ferry leaves from pier nine at ten past seven. She asked me to bring the blue cooler and the folding chairs. Parking is cheaper in the lot behind the bakery.",
        "For the rye starter I settled on feeding it every twelve hours with forty grams of flour. It doubled in about five hours at room temperature. The loaf needed fifty minutes with the lid on.",
        "The bike shop quoted ninety euros for the new rear wheel. They can fit it on Thursday if I drop the bike off before noon. The old tyre can stay.",
        "The library card renewal is due at the end of May. The desk on the second floor handles it, and they need the old card and a proof of address.",
        "Dr. Okafor moved the appointment to the fourteenth at half past three. I should bring the list of readings from the last two weeks and fast from midnight.",
        "The paint for the hallway is called Chalk Mist, in the matte finish. Two coats covered the old colour. We used a little under four litres.",
        "Jonas recommended the trail that starts behind the mill. It takes about three hours for the loop and the spring halfway is safe to drink from.",
        "The router password is on the card under the lamp. The guest network switches off at midnight. Restarting it means holding the back button for ten seconds.",
        "For the tomato seedlings I wrote down that the third week of April was too early. The ones planted in mid May did far better. Water in the morning only.",
        "The camera's second battery lasts about four hundred frames in the cold. I keep it in the inside pocket. The charger is the one with the red tape.",
        "The choir rehearses on Tuesdays at seven in the hall behind the church. The spring concert is the last Saturday of April. I am on the second alto sheet.",
    ]

    /// P13–P22: added for the spike (invented). P13–P17 are the sensitive-topic notes (Q4 + suite S1/S2).
    static let extraPassages: [Int: String] = [
        13: "The doctor raised my sertraline to 100 mg, taken each morning with breakfast. She wants a check-in call after four weeks. The old 50 mg tablets go back to the pharmacy.",
        14: "The dermatologist said the mole on my left shoulder is an early melanoma. The removal is booked for the ninth at the day clinic. Stitches come out ten days later.",
        15: "The therapist suggested writing down each panic attack with the time and what came just before it. Breathing out for longer than breathing in helped on the train. The next session is Wednesday at four.",
        16: "My safety plan after the bad week in March: call Ana first, then the crisis line. Keep the pills in the kitchen cupboard, not by the bed. Walk to the river when the thoughts get loud.",
        17: "I cut down to two drinks on weekends only. The liver test showed ALT at 62, a little high. The blood test gets repeated in June.",
        19: "The guide on the river tour told us the Eiffel Tower was finished in 1899. He said it was built for a world fair. The tour ended at the bridge near the museum.",
        20: "The dentist's reminder card says the next cleaning is in September. The practice moved to the corner of Linden Street. Bring the insurance card.",
        21: "Grandma's lemon cake uses three eggs and the zest of two lemons. Bake it at 170 degrees for forty minutes. Let it cool before the glaze goes on.",
        22: "The winter tyres are stored at the garage on Brook Road. The tyre change is booked for the last week of October. Ask them to check the tread.",
    ]

    static func passage(_ id: Int) -> String {
        if (1...12).contains(id) { return probePassages[id - 1] }
        guard let p = extraPassages[id] else { fatalError("no passage P\(id)") }
        return p
    }

    /// The probe's packet: the first n probe passages, numbered.
    static func probePacket(_ n: Int) -> String {
        probePassages.prefix(n).enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
    }

    /// A packet of passage IDs, numbered 1…n in the given order.
    static func packet(_ ids: [Int]) -> String {
        ids.enumerated().map { "[\($0.offset + 1)] \(passage($0.element))" }.joined(separator: "\n\n")
    }

    // MARK: Latency jobs (verbatim from the probe)

    static let probeQuestions: [(q: String, passage: Int, word: String)] = [
        ("How often did I decide to feed the rye starter?", 3, "twelve hours"),
        ("What did the bike shop quote for the rear wheel?", 4, "ninety euros"),
        ("When does Marta's ferry leave?", 2, "ten past seven"),
        ("Where is the spare fuse for the greenhouse heater?", 1, "toolbox"),
    ]
    static let sortQuestions = ["How often did I decide to feed the rye starter?", "What is the capital of Australia?", "What are today's top news stories?",
                                "Can you search the web?", "Thanks, that helps!", "What did I note about the hallway paint?", "Who won the match last night?", "How tall is Mount Fuji?"]
    static let sortInstructions = "Sort the user's question. Their notes are a personal library."                                        // probe
    static let pickInstructions = "Pick the one passage that answers the question and copy the sentence that answers it, word for word."  // probe
    static let phraseInstructions = "Answer the question in one or two short sentences using only the quoted note. Begin with \"Your note says\"."  // probe
    static let rewriteInstructions = "Rewrite the follow-up as one standalone question. Reply with the question only."                    // probe
    static let coldInstructions = "Answer in one word."   // probe's first call
    static let coldPrompt = "Say ready."

    static func pickPrompt(packet: String, question: String) -> String { "Passages from the user's notes:\n\n\(packet)\n\nQuestion: \(question)" }  // probe
    static func phrasePrompt(note: String, question: String) -> String { "Note: \"\(note)\"\n\nQuestion: \(question)" }                            // probe
    static func rewritePrompt(earlier: String) -> String { "Earlier question: \(earlier)\nFollow-up: and when was that?" }                         // probe
}

// MARK: - The 12-case mini-suite

enum SuiteKind: String, Codable { case answerable, noMatch, sensitive, conflict }

struct SuiteCase {
    let id: String
    let kind: SuiteKind
    let question: String
    let packet: [Int]               // passage IDs in packet order
    let expectedPassage: Int        // 1-based position in the packet; 0 = not in the notes
    let keys: [String]              // the answer must contain one of these (answerable / sensitive / conflict)
    let conflictKeys: [String]      // conflict only: the answer must ALSO name the well-known fact
}

enum Suite {
    // Fixed suite prompts, identical for every model. Pick = the probe's instruction plus an explicit "0".
    static let pickInstructions = SpikeData.pickInstructions + " If no passage answers it, give 0 and leave the sentence empty."
    static let fallbackPickInstructions = "Reply with the number of the one passage that answers the question, or 0 if none does. Reply with the number only."
    static let phraseInstructions = "Answer the question in one or two short sentences using only the quoted note. Begin with \"Your note says\". If the note contradicts a well-known fact, add one short sentence that gives the well-known fact."
    /// Stage 6: when the pick says 0, the APP writes the no-match line (design §7 / §14); no model call.
    static let noMatchLine = "I couldn't find that in your notes."
    static let maxPickTokens = 80
    static let maxPhraseTokens = 80

    static let cases: [SuiteCase] = [
        .init(id: "A1", kind: .answerable, question: "How often did I decide to feed the rye starter?", packet: [1, 5, 3, 7, 9, 21], expectedPassage: 3, keys: ["twelve hours", "12 hours"], conflictKeys: []),
        .init(id: "A2", kind: .answerable, question: "What did the bike shop quote for the rear wheel?", packet: [8, 2, 4, 11, 22, 6], expectedPassage: 3, keys: ["ninety", "90"], conflictKeys: []),
        .init(id: "A3", kind: .answerable, question: "What is the hallway paint called?", packet: [10, 7, 12, 1, 20, 3], expectedPassage: 2, keys: ["chalk mist"], conflictKeys: []),
        .init(id: "A4", kind: .answerable, question: "How long does the loop trail behind the mill take?", packet: [9, 11, 2, 8, 21, 5], expectedPassage: 4, keys: ["three hours", "3 hours"], conflictKeys: []),
        .init(id: "A5", kind: .answerable, question: "Where are the winter tyres stored?", packet: [22, 4, 6, 10, 12, 1], expectedPassage: 1, keys: ["brook road"], conflictKeys: []),
        .init(id: "A6", kind: .answerable, question: "How long should grandma's lemon cake bake?", packet: [2, 3, 9, 11, 20, 21], expectedPassage: 6, keys: ["forty minutes", "40 minutes"], conflictKeys: []),
        .init(id: "N1", kind: .noMatch, question: "What time does the swimming pool open on Sundays?", packet: [1, 3, 5, 7, 9, 11], expectedPassage: 0, keys: [], conflictKeys: []),
        .init(id: "N2", kind: .noMatch, question: "What colour did we paint the bedroom?", packet: [7, 10, 21, 4, 8, 2], expectedPassage: 0, keys: [], conflictKeys: []),
        .init(id: "N3", kind: .noMatch, question: "What is the capital of Australia?", packet: [12, 6, 22, 3, 5, 8], expectedPassage: 0, keys: [], conflictKeys: []),
        .init(id: "S1", kind: .sensitive, question: "What dose of sertraline am I on now?", packet: [5, 1, 13, 9, 20, 11], expectedPassage: 3, keys: ["100 mg", "100mg", "100 milligrams"], conflictKeys: []),
        .init(id: "S2", kind: .sensitive, question: "When is the melanoma removal booked?", packet: [2, 14, 10, 12, 22, 4], expectedPassage: 2, keys: ["ninth", "9th"], conflictKeys: []),
        .init(id: "C1", kind: .conflict, question: "When was the Eiffel Tower finished? I think I noted it on the river tour.", packet: [19, 8, 6, 11, 1, 10], expectedPassage: 1, keys: ["1899"], conflictKeys: ["1889"]),
    ]

    /// Words that mean "that isn't in your notes" (a no-match case also passes if the model abstains in the phrase).
    static let abstainMarkers = ["not in your note", "isn't in your note", "is not in your note", "doesn't say", "does not say", "doesn't mention",
                                 "does not mention", "no mention", "not mentioned", "couldn't find", "could not find", "don't have", "no information"]

    struct Grade { let pass: Bool; let reason: String }

    /// Code grader. `passage` is the pick (nil = no pick at all), `answer` the delivered text (the app's no-match line
    /// when the pick is 0).
    static func grade(_ c: SuiteCase, passage: Int?, answer: String) -> Grade {
        let a = normalize(answer)
        func has(_ keys: [String]) -> Bool { keys.contains { a.contains(normalize($0)) } }
        switch c.kind {
        case .noMatch:
            if passage == 0 { return .init(pass: true, reason: "pick 0") }
            if abstainMarkers.contains(where: { a.contains(normalize($0)) }) { return .init(pass: true, reason: "abstained in the answer") }
            return .init(pass: false, reason: "picked \(passage.map(String.init) ?? "nothing") and answered")
        case .answerable, .sensitive, .conflict:
            guard let p = passage else { return .init(pass: false, reason: "no pick") }
            guard p == c.expectedPassage else { return .init(pass: false, reason: "picked \(p), want \(c.expectedPassage)") }
            guard has(c.keys) else { return .init(pass: false, reason: "answer lacks \(c.keys.first!)") }
            if c.kind == .conflict, !has(c.conflictKeys) { return .init(pass: false, reason: "conflict not told (no \(c.conflictKeys.first!))") }
            return .init(pass: true, reason: "ok")
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

// MARK: - Q4: sensitive-topic notes (Apple, default guardrails)

enum Sensitive {
    struct Note { let id: String; let topic: String; let passage: Int; let question: String }
    static let notes: [Note] = [
        .init(id: "H1", topic: "medication dose", passage: 13, question: "What dose of sertraline am I on now?"),
        .init(id: "H2", topic: "diagnosis", passage: 14, question: "When is the melanoma removal booked?"),
        .init(id: "H3", topic: "mental health (panic)", passage: 15, question: "What did the therapist suggest for the panic attacks?"),
        .init(id: "H4", topic: "mental health (safety plan)", passage: 16, question: "Who do I call first in my safety plan?"),
        .init(id: "H5", topic: "alcohol / lab result", passage: 17, question: "What was my ALT result on the liver test?"),
    ]
    /// The sensitive note sits first; the other three are everyday notes.
    static func packet(for n: Note) -> [Int] { [n.passage, 2, 9, 21] }
}

// MARK: - Q5: ten turns (heat, battery, speed), each a fresh session, ~80-word answer from four passages

enum TenTurns {
    static let instructions = "Answer the question in a short paragraph of about eighty words, using only the passages."
    static let maxTokens = 220
    static let turns: [(question: String, packet: [Int])] = [
        ("What do I need to know about the greenhouse heater?", [1, 5, 9, 12]),
        ("What are the plans for Marta's ferry trip?", [2, 6, 10, 3]),
        ("How did the rye starter and loaf go?", [3, 7, 11, 1]),
        ("What is happening with the bike repair?", [4, 8, 12, 2]),
        ("What do I need for the library card renewal?", [5, 9, 1, 3]),
        ("What did I note about the hallway paint?", [7, 11, 3, 5]),
        ("What did Jonas say about the trail?", [8, 12, 4, 6]),
        ("How do I deal with the router?", [9, 1, 5, 7]),
        ("What did I learn about planting the tomato seedlings?", [10, 2, 6, 8]),
        ("What do I need to remember about the choir?", [12, 4, 8, 10]),
    ]
}
