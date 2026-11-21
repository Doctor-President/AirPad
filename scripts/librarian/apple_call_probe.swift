// Sweep 2a, amend 21c — what one extra small Apple Intelligence call costs, so the "chain of small calls" has a price
// before 2b. Runs on this Mac as a plain command-line process (no app, no Simulator, no library: the passages below
// are invented). Each call uses a FRESH session, as the chain would.
//
//   xcrun swiftc -O -parse-as-library scripts/librarian/apple_call_probe.swift -o build/sweep2a/applecall/probe
//   build/sweep2a/applecall/probe [repeats=8] > build/sweep2a/applecall/result.json
//
// Jobs timed:  sort    guided generation, one enum value (which kind of question is this?)
//              pick4   guided generation, a passage number + one exact sentence, from 4 passages (~1,100 characters)
//              pick12  the same from 12 passages (~3,300 characters)
//              phrase  plain text, ≤ 80 tokens, from one quoted sentence (first word and whole reply timed)
//              rewrite plain text, ≤ 40 tokens (the shape of today's web-query rewrite, for comparison)
// Greedy sampling throughout. The first call of the process is reported apart (model load).
import Foundation
import FoundationModels

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

let passages: [String] = [
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
let questions: [(q: String, passage: Int, word: String)] = [
    ("How often did I decide to feed the rye starter?", 3, "twelve hours"),
    ("What did the bike shop quote for the rear wheel?", 4, "ninety euros"),
    ("When does Marta's ferry leave?", 2, "ten past seven"),
    ("Where is the spare fuse for the greenhouse heater?", 1, "toolbox"),
]
let sortQuestions = ["How often did I decide to feed the rye starter?", "What is the capital of Australia?", "What are today's top news stories?",
                     "Can you search the web?", "Thanks, that helps!", "What did I note about the hallway paint?", "Who won the match last night?", "How tall is Mount Fuji?"]

func packet(_ n: Int) -> String {
    passages.prefix(n).enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n\n")
}

func timed<T>(_ body: () async throws -> T) async -> (ms: Double, value: T?, error: String?) {
    let t = ContinuousClock.now
    do {
        let v = try await body()
        let d = ContinuousClock.now - t
        return (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15, v, nil)
    } catch {
        let d = ContinuousClock.now - t
        return (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15, nil, String(describing: error).prefix(120).description)
    }
}

func stats(_ v: [Double]) -> [String: Any] {
    guard !v.isEmpty else { return ["n": 0] }
    let s = v.sorted()
    return ["n": s.count, "medianMs": Int(s[s.count / 2]), "minMs": Int(s.first!), "maxMs": Int(s.last!)]
}

@main struct Probe {
    static func main() async {
        let reps = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 8
        var out: [String: Any] = [:]
        let model = SystemLanguageModel.default
        guard model.isAvailable else { print("{\"error\":\"Apple Intelligence is not available to this process\"}"); return }
        out["contextSize"] = model.contextSize
        let greedy = { (n: Int) in GenerationOptions(samplingMode: .greedy, maximumResponseTokens: n) }

        // The first call of the process, apart (model load).
        let cold = await timed { try await LanguageModelSession(instructions: "Answer in one word.").respond(to: "Say ready.", options: greedy(8)).content }
        out["firstCallMs"] = Int(cold.ms)

        var sortMs: [Double] = [], sortErr = 0, sortKinds: [String] = []
        var pick4: [Double] = [], pick12: [Double] = [], pickErr = 0, pickRight = 0, pickVerbatim = 0, pickN = 0
        var phraseFirst: [Double] = [], phraseAll: [Double] = [], phraseErr = 0, rewrite: [Double] = [], rewriteErr = 0
        var promptTokens: [String: Int] = [:]

        for r in 0..<reps {
            let sq = sortQuestions[r % sortQuestions.count]
            let s = await timed {
                try await LanguageModelSession(instructions: "Sort the user's question. Their notes are a personal library.")
                    .respond(to: sq, generating: Sorted.self, options: greedy(20)).content
            }
            if let v = s.value { sortMs.append(s.ms); if r < sortQuestions.count { sortKinds.append("\(v.kind)") } } else { sortErr += 1 }

            let case_ = questions[r % questions.count]
            for n in [4, 12] {
                let prompt = "Passages from the user's notes:\n\n\(packet(n))\n\nQuestion: \(case_.q)"
                if promptTokens["pick\(n)"] == nil { promptTokens["pick\(n)"] = (try? await model.tokenCount(for: prompt)) ?? -1 }
                let p = await timed {
                    try await LanguageModelSession(instructions: "Pick the one passage that answers the question and copy the sentence that answers it, word for word.")
                        .respond(to: prompt, generating: Pick.self, options: greedy(80)).content
                }
                if let v = p.value {
                    if n == 4 { pick4.append(p.ms) } else { pick12.append(p.ms) }
                    pickN += 1
                    if v.passage == case_.passage { pickRight += 1 }
                    let sentence = v.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sentence.isEmpty, (1...n).contains(v.passage), passages[v.passage - 1].contains(sentence) { pickVerbatim += 1 }
                } else { pickErr += 1 }
            }

            let quote = passages[case_.passage - 1]
            let t0 = ContinuousClock.now
            var first: Double? = nil
            let ph = await timed { () -> String in
                let stream = LanguageModelSession(instructions: "Answer the question in one or two short sentences using only the quoted note. Begin with \"Your note says\".")
                    .streamResponse(to: "Note: \"\(quote)\"\n\nQuestion: \(case_.q)", options: greedy(80))
                var last = ""
                for try await snap in stream {
                    if first == nil, !snap.content.isEmpty {
                        let d = ContinuousClock.now - t0
                        first = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                    }
                    last = snap.content
                }
                return last
            }
            if ph.value != nil, let f = first { phraseFirst.append(f); phraseAll.append(ph.ms) } else { phraseErr += 1 }

            let rw = await timed {
                try await LanguageModelSession(instructions: "Rewrite the follow-up as one standalone question. Reply with the question only.")
                    .respond(to: "Earlier question: \(questions[(r + 1) % questions.count].q)\nFollow-up: and when was that?", options: greedy(40)).content
            }
            if rw.value != nil { rewrite.append(rw.ms) } else { rewriteErr += 1 }
        }
        out["sort"] = stats(sortMs); out["sortErrors"] = sortErr; out["sortKinds"] = sortKinds
        out["pick4"] = stats(pick4); out["pick12"] = stats(pick12); out["pickErrors"] = pickErr
        out["pickRightPassage"] = "\(pickRight)/\(pickN)"; out["pickSentenceVerbatim"] = "\(pickVerbatim)/\(pickN)"
        out["phraseFirstWord"] = stats(phraseFirst); out["phraseWhole"] = stats(phraseAll); out["phraseErrors"] = phraseErr
        out["rewrite"] = stats(rewrite); out["rewriteErrors"] = rewriteErr
        out["promptTokens"] = promptTokens; out["repeats"] = reps
        let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
