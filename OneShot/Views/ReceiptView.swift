import SwiftUI

/// A paper-style receipt for a sale or refund. Rendered to an image for Share (which includes AirPrint).
struct ReceiptView: View {
    let sale: Sale
    let shopName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 4) {
                LogoTile(size: 40)
                Text(shopName.isEmpty ? String(localized: "Your shop") : shopName).font(.seed(.headline))
                Text(sale.date, format: .dateTime.day().month().year().hour().minute())
                    .font(.seed(.caption))
                    .foregroundStyle(Brand.muted)
                Text(sale.isRefund ? "Refund" : "Receipt").font(.seed(.caption, .bold)).textCase(.uppercase)
            }
            .frame(maxWidth: .infinity)
            dashes
            ForEach(Array(sale.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.name)
                    if abs(line.quantity) > 1 { Text("× \(abs(line.quantity))").foregroundStyle(Brand.muted) }
                    Spacer()
                    Text(line.amount.baht).monospacedDigit()
                }
                .font(.seed(.subheadline))
            }
            dashes
            HStack {
                Text("Total").font(.seed(.headline))
                Spacer()
                Text(sale.total.baht).font(.seed(.title3, .bold)).monospacedDigit()
            }
            HStack {
                Label(sale.method == .cash ? "Cash" : "PromptPay", systemImage: sale.method == .cash ? "banknote" : "qrcode")
                Spacer()
            }
            .font(.seed(.subheadline))
            .foregroundStyle(Brand.muted)
            if let received = sale.received, let change = sale.change {
                row("Received", received)
                row("Change", change)
            }
            dashes
            VStack(spacing: 2) {
                Text(verbatim: "Thank you · ขอบคุณค่ะ").font(.seed(.subheadline, .bold))
                if let id = sale.id {
                    Text("No. \(String(id.uuidString.prefix(8)))").font(.caption2.monospaced()).foregroundStyle(Brand.muted)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(width: 340)
        .background(.white)
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }

    private var dashes: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1).foregroundStyle(.gray.opacity(0.6))
    }

    private func row(_ title: LocalizedStringKey, _ amount: Decimal) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(amount.baht).monospacedDigit()
        }
        .font(.seed(.subheadline))
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { $0.move(to: CGPoint(x: 0, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
        }
    }

    /// The receipt as an image for ShareLink: AirDrop, Messages, Save, or Print.
    @MainActor
    static func image(_ sale: Sale, shopName: String) -> Image? {
        let renderer = ImageRenderer(content: ReceiptView(sale: sale, shopName: shopName))
        renderer.scale = 3
        return renderer.uiImage.map { Image(uiImage: $0) }
    }
}
