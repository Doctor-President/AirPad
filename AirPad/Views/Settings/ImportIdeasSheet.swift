import SwiftUI

struct ImportIdeasSheet: View {

    @Environment(CorpusStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var didImport = false

    private var detectedCount: Int { BatchParser.detectedCount(text: text) }
    private var willTruncate: Bool { detectedCount > BatchParser.maxNodes }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    // Text editor area
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste any text — notes, bullet lists, multi-paragraph writing…")
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.3))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.body)
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .tint(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.top, 8)

                    // Live preview line
                    HStack(spacing: 8) {
                        if detectedCount == 0 {
                            Text("No ideas detected yet")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.35))
                        } else if willTruncate {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text("\(detectedCount) detected — max \(BatchParser.maxNodes), first \(BatchParser.maxNodes) will be imported")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green.opacity(0.8))
                            Text("\(detectedCount) idea\(detectedCount == 1 ? "" : "s") detected")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .animation(.easeInOut(duration: 0.15), value: detectedCount)
                }
                .dismissKeyboardOnTapOutside()
            }
            .navigationTitle("Import Ideas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white.opacity(0.6))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        didImport = true
                        Task {
                            await store.batchImportText(text)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(detectedCount > 0 ? .white : .white.opacity(0.25))
                    .disabled(detectedCount == 0)
                }
            }
        }
        .presentationBackground(.black)
    }
}
