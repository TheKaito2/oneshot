import SwiftUI
import VisionKit

/// VisionKit's live barcode scanner. Reports each newly tracked barcode; a pack that flickers out of tracking
/// and straight back within `repeatDelay` isn't counted twice.
struct BarcodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    var onError: (String) -> Void = { _ in }
    var repeatDelay: TimeInterval = 1.5

    static var isUsable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], recognizesMultipleItems: true,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    // Started here, not in make: the scanner needs to be on screen first.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.parent = self
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { onError(message) }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var parent: BarcodeScanner
        private var lastSeen: [String: Date] = [:]

        init(parent: BarcodeScanner) { self.parent = parent }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let code = barcode.payloadStringValue else { continue }
                let now = Date()
                if let last = lastSeen[code], now.timeIntervalSince(last) < parent.repeatDelay { continue }
                lastSeen[code] = now
                parent.onScan(code)
            }
        }
    }
}

/// Last resort for a yellow item: scan its barcode once.
struct BarcodeSheet: View {
    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var done = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if BarcodeScanner.isUsable {
                    BarcodeScanner(onScan: { code in
                        guard !done else { return }
                        done = true
                        onCode(code)
                        dismiss()
                    }, onError: { error = $0 })
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Barcode scanning isn't available here", systemImage: "barcode.viewfinder")
                }
            }
            .overlay(alignment: .bottom) {
                if let error {
                    Text(error).padding().background(.yellow, in: .rect(cornerRadius: 8)).foregroundStyle(.black).padding()
                }
            }
            .navigationTitle("Scan the barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
