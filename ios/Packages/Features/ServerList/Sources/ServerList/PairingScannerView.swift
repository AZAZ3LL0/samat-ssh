import AVFoundation
import DesignSystem
import SwiftUI
import VisionKit

/// Full-screen camera that reads the QR code `pulse-agent pair` prints and hands over its text once.
struct PairingScannerView: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    /// Simulators and devices without a camera cannot scan; the manual form stays the only way there.
    static var isSupported: Bool { DataScannerViewController.isSupported }

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .authorized:
                    QRScanner(onScan: onScan)
                        .ignoresSafeArea()
                case .notDetermined:
                    ProgressView()
                default:
                    EmptyState(
                        title: String(localized: "No access to the camera", bundle: .module),
                        message: String(
                            localized: "Allow camera access for Pulse in Settings, or enter the address by hand.",
                            bundle: .module),
                        systemImage: "camera"
                    )
                }
            }
            .navigationTitle(Text("Scan QR code", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module)) { dismiss() }
                }
            }
        }
        .task {
            guard access == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .video)
            access = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // Scanning starts only once the controller is on screen; a failure leaves the camera preview idle.
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var delivered = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]
        ) {
            // The scanner keeps reporting the same code while it stays in view; one hand-over is enough.
            guard !delivered else { return }
            for case .barcode(let barcode) in addedItems {
                guard let payload = barcode.payloadStringValue else { continue }
                delivered = true
                dataScanner.stopScanning()
                onScan(payload)
                return
            }
        }
    }
}
