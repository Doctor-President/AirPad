import SwiftUI
import UIKit

// MD14 measurement/verify harness (trace-only — no app behavior). Reached via
// `-SPRCaretMeasure YES`. Drives an XCUITest synthesized tap into the REAL note
// editor in the Simulator and traces the caret event sequence, so the fix (the
// caret lands at the tap, not the end) can be verified in-sim with no device lap.
// Inert unless the launch arg is set — a single bool check per instrumented
// callback in Release, and the fixture view is DEBUG-only.

/// Append-only trace to `Documents/caret_trace.log` in the app container (CC reads
/// it via `simctl get_app_container`), mirrored to stdout as `CARET>`.
enum CaretTrace {
    static let enabled = UserDefaults.standard.bool(forKey: "SPRCaretMeasure")

    private static let url: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("caret_trace.log")
    private static let queue = DispatchQueue(label: "airpad.caret.trace")

    static func reset() {
        guard enabled else { return }
        queue.sync { try? Data().write(to: url) }
    }

    static func log(_ event: @autoclosure () -> String) {
        guard enabled else { return }
        let s = event()
        queue.sync {
            let line = Data((s + "\n").utf8)
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); try? fh.write(contentsOf: line); try? fh.close()
            } else {
                try? line.write(to: url)
            }
        }
        print("CARET> \(s)")
    }

    /// Compact selection descriptor. Flags when the caret sits at the very end.
    static func sel(_ tv: UITextView) -> String {
        let r = tv.selectedRange
        let len = tv.attributedText?.length ?? 0
        let atEnd = (r.location >= len && len > 0) ? " <END>" : ""
        return "loc=\(r.location) len=\(r.length) / textLen=\(len)\(atEnd)"
    }

    /// Text offset nearest the XCUITest normalized tap point — confirms the tap
    /// lands over a glyph (interior offset), not in empty space past the last one.
    static func geomLog(_ tv: UITextView, nx: CGFloat = 0.35, ny: CGFloat = 0.06) {
        guard enabled else { return }
        let p = CGPoint(x: nx * tv.bounds.width, y: ny * tv.bounds.height)
        let off = tv.closestPosition(to: p).map { tv.offset(from: tv.beginningOfDocument, to: $0) } ?? -1
        log("GEOM tapPoint=(\(Int(p.x)),\(Int(p.y))) bounds=\(Int(tv.bounds.width))x\(Int(tv.bounds.height)) closestOffset@tap=\(off)")
    }
}

#if DEBUG
/// Fixture: the REAL note editor (documentStyle + Source Serif 4, exactly as
/// TextEntryBody configures it) inside a SwiftUI `ScrollView` (as NodeDetailView
/// hosts it), plus two vanilla `UITextView` controls. An XCUITest coordinate tap
/// lands mid-first-line; the trace shows the note editor's caret lands at the tap
/// (matching the controls), proving the fix.
struct CaretMeasureView: View {
    static let fixture = """
    Tap the middle of THIS first line to measure the caret.
    Second line has a [link](https://apple.com) in it.
    - [ ] a checklist item on the third line
    Fourth line, more words so the note is comfortably multi-line and tall.
    Fifth line so the end offset is far from the first line we tap.
    """

    @State private var text = CaretMeasureView.fixture

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RichTextEditor(text: $text, placeholder: "note…", documentStyle: true, documentFont: .sourceSerif4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(white: 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(20)

                PlainControlTextView(id: "controlTextView", scrollEnabled: true)
                    .frame(height: 160).padding(20)
                    .background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(20)

                PlainControlTextView(id: "controlNoScroll", scrollEnabled: false)
                    .frame(height: 160).padding(20)
                    .background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 16)).padding(20)

                Spacer(minLength: 500)
            }
        }
        .onAppear {
            CaretTrace.reset()
            CaretTrace.log("READY fixture.len=\((CaretMeasureView.fixture as NSString).length)")
        }
    }
}

/// Vanilla UITextView control — the tap-trustworthiness baseline (a healthy text
/// view places the caret at the tap; the note editor must match it).
private struct PlainControlTextView: UIViewRepresentable {
    let id: String
    let scrollEnabled: Bool
    func makeCoordinator() -> Coord { Coord(id: id) }
    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.text = "CONTROL \(id) — tap the middle of this first line.\nSecond line of the control.\nThird line.\nFourth line so the end offset is far away."
        tv.font = .preferredFont(forTextStyle: .body)
        tv.isScrollEnabled = scrollEnabled
        tv.delegate = context.coordinator
        tv.accessibilityIdentifier = id
        return tv
    }
    func updateUIView(_ uiView: UITextView, context: Context) {}
    final class Coord: NSObject, UITextViewDelegate {
        let id: String
        init(id: String) { self.id = id }
        func textViewDidBeginEditing(_ tv: UITextView) { CaretTrace.log("[\(id)] didBeginEditing \(CaretTrace.sel(tv))") }
        func textViewDidChangeSelection(_ tv: UITextView) { CaretTrace.log("[\(id)] didChangeSelection \(CaretTrace.sel(tv))") }
    }
}
#endif
