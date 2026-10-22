import AVFoundation
import SwiftUI

/// The camera, looking for Nocturnal's pairing QR code. Reports the first code it reads.
struct QRScannerSheet: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        NavigationStack {
            Group {
                if denied {
                    ContentUnavailableView {
                        Label("Camera access is off", systemImage: "camera")
                    } description: {
                        Text("Allow it in Settings, or paste the code instead.")
                    } actions: {
                        Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                            .buttonStyle(.glass)
                    }
                } else {
                    CameraView(found: found, denied: { denied = true })
                        .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
                        .padding(Theme.gutter)
                        .accessibilityLabel("Camera viewfinder")
                }
            }
            .navigationTitle("Scan the QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } } }
        }
    }
}

private struct CameraView: UIViewRepresentable {
    let found: (String) -> Void
    let denied: () -> Void

    func makeCoordinator() -> Scanner { Scanner(found: found) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        AVCaptureDevice.requestAccess(for: .video) { ok in
            Task { @MainActor in ok ? context.coordinator.start() : denied() }
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: Scanner) { coordinator.stop() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Scanner: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        private let found: (String) -> Void
        private var done = false

        init(found: @escaping (String) -> Void) { self.found = found }

        func start() {
            guard session.inputs.isEmpty, let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let s = session
            Task.detached { s.startRunning() }   // blocks while the camera starts
        }

        func stop() {
            let s = session
            Task.detached { s.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            MainActor.assumeIsolated {
                guard !done else { return }
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                found(text)
            }
        }
    }
}
