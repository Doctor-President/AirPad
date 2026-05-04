import SwiftUI
import UIKit

struct QuikCaptureView: View {

    var body: some View {
        ZStack {
            Color(hex: "#07070A").ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    exitPill
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                HStack(spacing: 0) {
                    Spacer()
                    captureButton(symbol: "mic.fill", label: "Voice") {
                        // TODO: Step 4
                    }
                    Spacer()
                    captureButton(symbol: "camera.fill", label: "Camera") {
                        // TODO: Step 4
                    }
                    Spacer()
                    captureButton(symbol: "pencil", label: "Text") {
                        // TODO: Step 4
                    }
                    Spacer()
                    captureButton(symbol: "doc.on.clipboard.fill", label: "Clipboard") {
                        // TODO: Step 4
                    }
                    Spacer()
                }
                .padding(.bottom, 48)
            }
        }
    }

    private var exitPill: some View {
        Button {
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
        } label: {
            Text("Exit QuikCapture ↩")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(hex: "#1B59C2"))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func captureButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white)
        }
    }
}
