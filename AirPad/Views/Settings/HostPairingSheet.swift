// HostPairingSheet — "Connect to your computer". Scans the desktop AirPad Host's pairing
// QR (or accepts a pasted code), parses it into a HostPairing, and persists it. Once paired,
// the Librarian/chat routes through the Host over the tunnel with app-layer E2E (ModelRouter
// resolves `.host` first). A paired state can be cleared here too (re-pair / unpair).

import AVFoundation
import SwiftUI

struct HostPairingSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var existing: HostPairing? = HostPairing.load()
    @State private var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var pasteCode = ""
    @State private var error: String?
    @State private var connectedHost: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let host = connectedHost {
                        connected(host)
                    } else if let p = existing {
                        alreadyPaired(p)
                    } else {
                        pairing
                    }
                }
                .padding(20)
            }
            .background(AppearancePalette.bgBase.ignoresSafeArea())
            .navigationTitle("Connect to your computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(AppearancePalette.ink)
                }
            }
        }
        .presentationBackground(AppearancePalette.bgBase)
    }

    // MARK: - states

    @ViewBuilder private var pairing: some View {
        Text("Scan the QR code shown by the AirPad Host on your Mac — or paste the pairing code.")
            .font(.subheadline)
            .foregroundStyle(AppearancePalette.ink.opacity(0.7))

        if cameraAuthorized {
            QRScannerView { code in accept(code) }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppearancePalette.ink.opacity(0.15)))
        } else {
            Button {
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async { cameraAuthorized = ok }
                }
            } label: {
                Label("Enable camera to scan", systemImage: "camera")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppearancePalette.ink.opacity(0.8))
                    .padding(.vertical, 12).frame(maxWidth: .infinity)
                    .background(AppearancePalette.ink.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Or paste the pairing code")
                .font(.caption.weight(.semibold)).foregroundStyle(AppearancePalette.ink.opacity(0.4))
            HStack {
                TextField("{ \"tunnelURL\": … }", text: $pasteCode, axis: .vertical)
                    .font(.footnote.monospaced())
                    .lineLimit(1...4)
                    .padding(10)
                    .background(AppearancePalette.ink.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Connect") { accept(pasteCode) }
                    .font(.subheadline.weight(.semibold))
                    .disabled(pasteCode.isEmpty)
            }
        }

        if let e = error {
            Text(e).font(.caption).foregroundStyle(.orange.opacity(0.85))
        }
    }

    @ViewBuilder private func alreadyPaired(_ p: HostPairing) -> some View {
        row(icon: "checkmark.seal.fill", tint: .green,
            title: "Paired with \(p.displayHost)",
            subtitle: "Chats route to your computer's model, end-to-end encrypted.")
        Button(role: .destructive) {
            HostPairing.clear(); existing = nil
        } label: {
            Label("Unpair this computer", systemImage: "xmark.circle")
                .font(.subheadline.weight(.medium))
        }
        Text("Re-scan a new QR to pair with a different computer (this rotates the secret).")
            .font(.caption2).foregroundStyle(AppearancePalette.ink.opacity(0.4))
        Divider().overlay(AppearancePalette.ink.opacity(0.1))
        pairing // allow re-pairing inline
    }

    @ViewBuilder private func connected(_ host: String) -> some View {
        row(icon: "checkmark.seal.fill", tint: .green,
            title: "Connected to \(host)",
            subtitle: "You can now chat with your computer's model from anywhere.")
        Button("Done") { dismiss() }
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 12).frame(maxWidth: .infinity)
            .background(AppearancePalette.ink.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func row(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppearancePalette.ink)
                Text(subtitle).font(.caption).foregroundStyle(AppearancePalette.ink.opacity(0.6))
            }
            Spacer()
        }
        .padding(14).background(AppearancePalette.ink.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - accept

    private func accept(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = HostPairing.parse(trimmed) else {
            error = "That doesn't look like a valid AirPad Host code."
            return
        }
        error = nil
        p.persist()
        // clearing any stale endpoint is not required — ModelRouter resolves .host first.
        connectedHost = p.displayHost
        existing = p
    }
}
