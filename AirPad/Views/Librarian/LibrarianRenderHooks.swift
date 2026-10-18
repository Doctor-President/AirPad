#if DEBUG
import Foundation

/// live-24 (3)+(5) — DEBUG render hooks for the Librarian stills (ported from live-21's `RenderVariant`, which was a
/// render-only branch): `-RenderLongAnswer YES` opens this synthetic chat at full; `-RenderHideText YES` hides the
/// transcript and the pill text so a still is backdrop only (the contrast numbers). Sample-Library register only.
enum LibrarianRenderHooks {
    static let longAnswerChat: Chat = {
        let epoch = Date(timeIntervalSince1970: 1_760_500_000)
        let answer = """
        Across your notes, three threads keep coming back: **paper**, **light**, and **grammar**. The paper notes are the most concrete — Tomoe River's thinness, how fountain-pen ink sits on top of it rather than sinking in, and the way a heavy nib shows through to the next page. [1]

        The light notes are looser. You describe the cucumber-water light of late afternoon, the colour of a north-facing room in winter, and a photograph whose shadows went blue rather than grey. They read less like observations than like a vocabulary you are building, one adjective at a time. [2]

        The grammar notes are the most argued. The gerund note sets out the difference between a verbal noun and a participle, then tests it against sentences you collected from novels — and admits two of them still don't fit either rule cleanly. [3]

        If you want one entry to start from, the gerund note is the most developed: it has the clearest question, the most examples, and a list of what you still want to check. The paper and light threads would each benefit from a single summary note that gathers the scattered observations in one place.
        """
        let cites = [1, 2, 3].map { i in
            ChatSession.Message.Citation(index: i, nodeID: "render-\(i)", title: ["Tomoe River paper", "Cucumber-water light", "On the Gerund"][i - 1],
                                         snippet: "Synthetic citation \(i).")
        }
        return Chat(id: UUID(), title: "What threads run through my notes?", createdAt: epoch, updatedAt: epoch,
                    messages: [.init(role: .user, text: "What threads run through my notes, and where should I start?"),
                               .init(role: .assistant, text: answer, citations: cites)])
    }()

    /// live-26 (3f) — `-RenderTableAnswer 2x3|5x46|8x10|1col`: a synthetic answer holding that table (ChatTableFixtures).
    static func tableChat(_ name: String) -> Chat? {
        guard let f = ChatTableFixtures.all.first(where: { $0.name == name }) else { return nil }
        let epoch = Date(timeIntervalSince1970: 1_760_600_000)
        let answer = "Here is the table you asked for.\n\n" + f.md + "\n\nTap the table to open it full screen."
        return Chat(id: UUID(), title: "A table (\(name))", createdAt: epoch, updatedAt: epoch,
                    messages: [.init(role: .user, text: "Make me a table."), .init(role: .assistant, text: answer)])
    }
}
#endif
