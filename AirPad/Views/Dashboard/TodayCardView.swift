import SwiftUI

/// Dashboard C1 — self-contained Today section.
///
/// Layout (top → bottom):
///   1. Date header (formatted "Friday, May 22")
///   2. System insight stub copy
///   3. Journal entry prompt — the one interactive affordance in C1; tap
///      forwards to `onJournalPromptTap` for the host to surface a placeholder.
///   4. Activity log stub list
///
/// All copy is hardcoded for C1. In C2+ each section is driven by real data
/// (date stays formatted from `Date()`; insight + activity from a service;
/// journal prompt rotates from a prompt library).
struct TodayCardView: View {

    let now: Date
    let recentNodes: [Node]
    let onJournalPromptTap: () -> Void
    let onRecentTap: (Node) -> Void

    init(
        now: Date = Date(),
        recentNodes: [Node] = [],
        onJournalPromptTap: @escaping () -> Void = {},
        onRecentTap: @escaping (Node) -> Void = { _ in }
    ) {
        self.now = now
        self.recentNodes = recentNodes
        self.onJournalPromptTap = onJournalPromptTap
        self.onRecentTap = onRecentTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            dateHeader
            insightSection
            journalPrompt
            activityLog
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(white: 0.08))
        )
    }

    // MARK: - Date

    private var dateHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .tracking(0.8)
            Text(longDate(now))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    // MARK: - Insight

    private var insightSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Insight")
            Text("Your reading and field notes have been converging on the same set of questions this week.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
                .lineSpacing(2)
        }
    }

    // MARK: - Journal prompt

    private var journalPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Journal")
            Button(action: onJournalPromptTap) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("What's on your mind today?")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil.line")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.14))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Activity log

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Activity")
            VStack(alignment: .leading, spacing: 8) {
                if recentNodes.isEmpty {
                    Text("No recent activity")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    ForEach(recentNodes.prefix(3)) { node in
                        Button { onRecentTap(node) } label: {
                            activityRow(node: node)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func activityRow(node: Node) -> some View {
        HStack(spacing: 10) {
            Text(node.title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
            Text("·")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
            Text(node.updatedAt, style: .relative)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Shared

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase)
            .tracking(0.8)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        TodayCardView()
            .padding(16)
    }
}
