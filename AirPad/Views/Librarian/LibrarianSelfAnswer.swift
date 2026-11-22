import Foundation

/// Sweep 2b · 1d/1e (decisions 2026-11-21) — a question about the Librarian itself ("Can you search the web?", "What
/// can you do?") is answered by the APP from real settings: never searched, never the model's guess. Checked at the top
/// of `LibrarianState.groundedSend`, in both modes. A phrase rule, like `looksLikeSearchIntent` (no classifier): the
/// question must END at the capability, so a request ("Can you search the web for today's news?", "Can you look up the
/// population of France online?", "What can you do about a leaky tap?") is not one.
enum LibrarianSelfQuestion {
    static let pattern = #"^\s*(?:(?:hey|so|ok|okay),?\s+)?(?:(?:can|could|do|will|would|are)\s+you\s+(?:be\s+)?(?:able\s+to\s+)?(?:have\s+)?(?:(?:search|browse|access|use|go|get|look|check|surf|reach)(?:\s+(?:things|stuff))?(?:\s+up)?\s+)?(?:(?:on|onto|to|the|into)\s+){0,2}(?:web|internet|online|google)(?:\s+(?:access|search))?|what\s+(?:else\s+)?can\s+you\s+do|what\s+can\s+you\s+help\s+(?:me\s+)?with|what\s+are\s+you\s+(?:able\s+to\s+do|capable\s+of|good\s+at|for)|what\s+do\s+you\s+do|who\s+are\s+you|what\s+are\s+you|how\s+do\s+you\s+work)(?:\s+for\s+me)?[\s?.!]*$"#
    static func matches(_ q: String) -> Bool {
        q.replacingOccurrences(of: "\u{2019}", with: "'")
            .range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Sweep 2b · 1e — the "What can you do?" answer, built from real settings (T's wording, decisions 2026-11-21). Pure.
enum LibrarianSelfAnswer {
    enum Web: Equatable {
        case on
        case off
        /// The switch is on but the chosen provider has no key (`keyName`: "Brave Search" / "Tavily").
        case needsKey(String)
    }
    static let intro = "I'm the Librarian. I can find things in your library, answer from them, and show you the entries I used. I can also help you think: bounce ideas around, get past a blank page, or talk something through."
    static let webOn = "Web search is on, so I can look things up online."
    /// The Settings link renders as a link (`airpad-settings://websearch`, handled by the transcript).
    static let webOff = "Web search is off. [Turn it on in Settings → Web search.](airpad-settings://websearch)"
    static func webNeedsKey(_ keyName: String) -> String {
        "Web search needs a \(keyName) key. [Add one in Settings → Web search.](airpad-settings://websearch)"
    }
    static let appleModelLine = "I'm running on Apple Intelligence, which is best with your notes and ideas; for facts about the world, I'll say when an answer isn't from your notes."
    static func modelLine(_ name: String) -> String {
        "I'm running on \(name), which is good with your notes and with general knowledge."
    }
    static let strongerBrain = "You can give me a stronger brain in Settings → Models."

    static func webLine(_ web: Web) -> String {
        switch web {
        case .on: return webOn
        case .off: return webOff
        case .needsKey(let k): return webNeedsKey(k)
        }
    }

    /// `apple`: Apple Intelligence answers (its own line); otherwise `modelName` (the model's friendly name).
    /// `otherOptionExists`: more than one usable brain on this device (`LibrarianState.brainOptionCount` > 1).
    static func text(apple: Bool, modelName: String, web: Web, otherOptionExists: Bool) -> String {
        let model = (apple ? appleModelLine : modelLine(modelName)) + (otherOptionExists ? " " + strongerBrain : "")
        return [intro, webLine(web), model].joined(separator: "\n\n")
    }

    /// Sweep 2b · 1f (decisions 2026-11-21) — one plain sentence at the moment it matters: the question needs the web,
    /// search is on, and the model answering is MEASURED not to use tools (a real tool round-trip failed on the Host's
    /// probe; an unprobed claim never counts).
    static let cantSearchLine = "This model can't search the web. Switch brains in Settings → Models."
    static func cantSearch(_ m: CatalogModel?) -> Bool { m.map { $0.toolsMeasured && !$0.supportsTools } ?? false }
}

#if DEBUG
/// `-LibrarianSelfAnswerSelfTest` — the detector (questions about the Librarian vs requests that merely mention the web),
/// the exact answers per route × web state × other-option, and the REAL send path in both modes (app-written, nothing
/// searched, no model call).
enum LibrarianSelfAnswerSelfTest {
    @MainActor static func run(store: CorpusStore) async -> String {
        var rows: [(String, Bool, String)] = []
        func row(_ n: String, _ ok: Bool, _ d: String = "") { rows.append((n, ok, d)) }
        let yes = ["Can you search the web?", "What can you do?", "Are you able to look things up online?",
                   "Do you have web access?", "Can you access the internet?", "can you browse the web", "Could you go online?",
                   "Who are you?", "How do you work?", "What else can you do?", "What can you help me with?",
                   "What are you capable of?", "Can you use Google?"]
        let no = ["Can you search the web for today's news?", "Can you look up the population of France online?",
                  "What can you do about a leaky tap?", "What are today's top news stories?", "What is the capital of France?",
                  "Who are you voting for in the poll I wrote about?", "Search the web for the Lakeview telescope news",
                  "How do you work out compound interest?", "What did I write about the web?"]
        let missYes = yes.filter { !LibrarianSelfQuestion.matches($0) }, hitNo = no.filter(LibrarianSelfQuestion.matches)
        row("detector-matches-questions-about-the-librarian", missYes.isEmpty, missYes.joined(separator: " | "))
        row("detector-leaves-requests-alone", hitNo.isEmpty, hitNo.joined(separator: " | "))

        let intro = "I'm the Librarian. I can find things in your library, answer from them, and show you the entries I used. I can also help you think: bounce ideas around, get past a blank page, or talk something through."
        let apple = "I'm running on Apple Intelligence, which is best with your notes and ideas; for facts about the world, I'll say when an answer isn't from your notes."
        let brain = " You can give me a stronger brain in Settings → Models."
        let on = "Web search is on, so I can look things up online."
        let off = "Web search is off. [Turn it on in Settings → Web search.](airpad-settings://websearch)"
        let key = "Web search needs a Brave Search key. [Add one in Settings → Web search.](airpad-settings://websearch)"
        let qwen = "I'm running on Qwen3.5 9B, which is good with your notes and with general knowledge."
        let cases: [(String, String, String)] = [
            ("apple-on-only", LibrarianSelfAnswer.text(apple: true, modelName: "", web: .on, otherOptionExists: false), [intro, on, apple].joined(separator: "\n\n")),
            ("apple-off-other", LibrarianSelfAnswer.text(apple: true, modelName: "", web: .off, otherOptionExists: true), [intro, off, apple + brain].joined(separator: "\n\n")),
            ("apple-needs-key", LibrarianSelfAnswer.text(apple: true, modelName: "", web: .needsKey("Brave Search"), otherOptionExists: false), [intro, key, apple].joined(separator: "\n\n")),
            ("host-on-other", LibrarianSelfAnswer.text(apple: false, modelName: "Qwen3.5 9B", web: .on, otherOptionExists: true), [intro, on, qwen + brain].joined(separator: "\n\n")),
            ("server-off-only", LibrarianSelfAnswer.text(apple: false, modelName: "Qwen3.5 9B", web: .off, otherOptionExists: false), [intro, off, qwen].joined(separator: "\n\n")),
        ]
        for c in cases { row("answer-\(c.0)", c.1 == c.2, c.1 == c.2 ? "" : c.1.replacingOccurrences(of: "\n", with: "⏎")) }

        // 1f — the measured no-tools model, and nothing else, can't search.
        func cm(tools: Bool, measured: Bool) -> CatalogModel {
            CatalogModel(tag: "t", display: "t", state: "installed-loaded", sizeBytes: 0, tier: 16, recommended: false, capabilities: [],
                         verified: true, note: "", supportsThinking: false, thinkingMeasured: true, thinkingToggleable: false,
                         toggleMeasured: true, supportsTools: tools, toolsMeasured: measured, capability: "", posture: "")
        }
        row("cant-search-measured-no-tools-only", LibrarianSelfAnswer.cantSearch(cm(tools: false, measured: true))
            && !LibrarianSelfAnswer.cantSearch(cm(tools: false, measured: false)) && !LibrarianSelfAnswer.cantSearch(cm(tools: true, measured: true))
            && !LibrarianSelfAnswer.cantSearch(nil))
        row("cant-search-line", LibrarianSelfAnswer.cantSearchLine == "This model can't search the web. Switch brains in Settings → Models.")

        // Sweep 2b · 1g — T saw "… Web search is off. [Turn it on in Settings → Web search." (mac-sweep-1 step 12): a stray
        // "[" before a link. Every app line carrying the Settings link, through every path that shows it: the block
        // parser + inline renderer (the bubble), the one-line label (the chat list), the math pass. Each must give ONE
        // link run to airpad-settings://websearch and never a literal "[" / "](".
        let linkLines = [ChatSession.noWebNewsLine + " " + off, off, key, ChatSession.noWebNewsLine + " " + key,
                         LibrarianSelfAnswer.text(apple: true, modelName: "", web: .off, otherOptionExists: true)]
        for (i, line) in linkLines.enumerated() {
            let blocks = MarkdownBlockParser.parse(line)
            var links = 0, shown = ""
            for b in blocks {
                guard case let .paragraph(t) = b else { shown += "<\(b)>"; continue }
                for face in [EntryBodyFont.sourceSerif4, .sfPro] {
                    let a = MarkdownBlockView.inline(t, face: face)
                    if face == .sfPro { shown += String(a.characters) + "⏎" }
                    if face == .sfPro { links += a.runs.filter { $0.link?.absoluteString == "airpad-settings://websearch" }.count }
                }
            }
            let label = MarkdownPlain.label(line)
            row("settings-link-\(i)-one-link-no-bracket", links == 1 && !shown.contains("[") && !shown.contains("](")
                && blocks.allSatisfy { if case .paragraph = $0 { return true } else { return false } },
                "links=\(links) shown=\(shown.prefix(140))")
            row("settings-link-\(i)-preview-no-bracket", !label.contains("[") && !label.contains("](") && label.contains("Settings → Web search"),
                String(label.suffix(80)))
            row("settings-link-\(i)-math-pass-untouched", MathText.inline(line) == line)
        }

        // The real send path, web search switched off (no network): General and Library mode both get the app's answer.
        let d = UserDefaults.standard, priorEnabled = d.object(forKey: WebSearchBackend.enabledKey)
        d.set(false, forKey: WebSearchBackend.enabledKey)
        ModelRouter.debugLastApplePrompt = ""
        let priorCorpus = LibrarianState().corpusAware   // persisted: put back after
        for library in [false, true] {
            let lib = LibrarianState(), chat = ChatSession()
            lib.corpusAware = library
            await lib.groundedSend(query: "What can you do?", store: store, chat: chat)
            let a = chat.messages.last { $0.role == .assistant }
            row("send-\(library ? "library" : "general")-app-answers", a?.text.hasPrefix(intro) == true && a?.text.contains(off) == true
                && a?.provenance == nil && a?.readReceipt == nil && !chat.messages.contains { $0.role == .activity },
                String((a?.text ?? "nil").prefix(80)))
        }
        row("send-no-model-call", ModelRouter.debugLastApplePrompt.isEmpty)
        LibrarianState().corpusAware = priorCorpus
        if let priorEnabled { d.set(priorEnabled, forKey: WebSearchBackend.enabledKey) } else { d.removeObject(forKey: WebSearchBackend.enabledKey) }
        let fails = rows.filter { !$0.1 }
        return (fails.isEmpty ? "PASS — \(rows.count)/\(rows.count)" : "FAIL — \(rows.count - fails.count)/\(rows.count)")
            + rows.map { "\n\($0.1 ? "ok  " : "FAIL") \($0.0)\($0.2.isEmpty ? "" : " — \($0.2)")" }.joined()
    }
}
#endif
