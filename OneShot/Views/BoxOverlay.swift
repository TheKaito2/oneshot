import SwiftUI

struct Mark: Identifiable {
    let id: Int
    /// Normalised, Vision space (origin bottom-left).
    let rect: CGRect
    let label: String
    let color: Color
}

/// Draws boxes over an image shown in the same frame: the live preview (aspect fill) or a locked photo (aspect fit).
struct BoxOverlay: View {
    let marks: [Mark]
    let imageSize: CGSize
    var fill = true
    /// The locked frame's boxes draw themselves in; live boxes just appear.
    var reveal = false

    @State private var drawn = false

    var body: some View {
        GeometryReader { geometry in
            ForEach(marks) { mark in
                let frame = Self.viewRect(for: mark.rect, imageSize: imageSize, in: geometry.size, fill: fill)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .trim(from: 0, to: !reveal || drawn ? 1 : 0)
                    .stroke(mark.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: frame.width, height: frame.height)
                    .overlay(alignment: .topLeading) {
                        Text(mark.label)
                            .font(.seed(.caption, .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(mark.color, in: .rect(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(.black)
                            .offset(x: 4, y: -10)
                    }
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard reveal else { return }
            withAnimation(.easeOut(duration: 0.55)) { drawn = true }
        }
    }

    /// Vision rect (normalised, origin bottom-left) to view points, for an image aspect-filled (or fitted) into `viewSize`.
    static func viewRect(for rect: CGRect, imageSize: CGSize, in viewSize: CGSize, fill: Bool = true) -> CGRect {
        let widthScale = viewSize.width / imageSize.width, heightScale = viewSize.height / imageSize.height
        let scale = fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let originX = (viewSize.width - shown.width) / 2
        let originY = (viewSize.height - shown.height) / 2
        return CGRect(x: originX + rect.minX * shown.width,
                      y: originY + (1 - rect.maxY) * shown.height,
                      width: rect.width * shown.width,
                      height: rect.height * shown.height)
    }
}
