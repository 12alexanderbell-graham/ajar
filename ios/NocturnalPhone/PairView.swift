import SwiftUI

/// Until this phone has a key: scan the QR code Nocturnal shows on the computer, or paste its code. "Try the demo"
/// shows every screen with a pretend computer.
struct PairView: View {
    @Environment(Computer.self) private var computer
    @State private var code = ""
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image("AppMark")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nocturnal").font(.system(size: 34, weight: .bold)).tracking(-0.7)
                    Text("Pair with your Mac or PC").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 34)
            .padding(.bottom, 26)

            Button { scanning = true } label: {
                Text("Scan QR Code").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)

            Text("On your computer, open Nocturnal and choose Pair a Phone.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)

            HStack(spacing: 10) {
                TextField("Or paste the code", text: $code)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(pairFromCode)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))
                Button("Pair", action: pairFromCode)
                    .font(.headline)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(code.isEmpty)
            }
            if let error {
                Text(error).foregroundStyle(.red).padding(.top, 12)
            }
            Spacer()
            Button("Try the demo") { computer.startDemo() }
                .font(.headline)
                .buttonStyle(.glass)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, Theme.gutter)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            QRScannerSheet { text in
                scanning = false
                if let p = Pairing(text: text) { computer.pair(p) } else { error = "That QR code isn't from Nocturnal." }
            }
        }
    }

    private func pairFromCode() {
        guard let p = Pairing(text: code) else { error = "That doesn't look like a Nocturnal pairing code."; return }
        error = nil
        computer.pair(p)
    }
}

#Preview {
    PairView().environment(Computer())
}
