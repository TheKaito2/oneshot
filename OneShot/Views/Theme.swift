import SwiftUI
import UIKit

/// OneShot's look, after kristpaulstudio.com: warm neutrals on a fixed 80 pt hairline grid, coral accents, and the
/// site's liquid glass for content panels (a faint fill, inset edge lines, a rim light).
/// iOS Liquid Glass stays on controls and on anything floating over the camera. No gradients except that rim.
/// Green and yellow keep meaning "sure" and "check".
enum Brand {
    static let canvas = Color(light: 0xFAF9F5, dark: 0x181715)
    static let card = Color(light: 0xEFE9DE, dark: 0x252320)
    static let hairline = Color(light: 0xE6DFD8, dark: 0x2C2924)
    static let ink = Color(light: 0x141413, dark: 0xFAF9F5)
    static let body = Color(light: 0x3D3D3A, dark: 0xC5C1B6)
    static let muted = Color(light: 0x6C6A64, dark: 0xA09D96)
    static let mutedSoft = Color(light: 0x8E8B82, dark: 0x6C6A64)
    /// Coral, for links, icons and key accents. Light mode takes the deeper shade to keep 4.5:1 on cream.
    static let accent = Color(light: 0xA9583E, dark: 0xCC785C)
    /// Behind white text (Ring up, Charge, Paid): the site's contrast-fixed button coral.
    static let buttonFill = Color(rgb: 0xA9583E)

    // Chart series: flat warm colours told apart by hue and lightness.
    static let sand = Color(light: 0xB07F2E, dark: 0xD9A65B)
    static let sage = Color(light: 0x5E7F5B, dark: 0x8DA88A)
    static let sky = Color(light: 0x4E7894, dark: 0x7FA3BF)
    static let mauve = Color(light: 0x7E6394, dark: 0xA58AB8)
    static let palette = [accent, sand, sage, sky, mauve]

    // Status colours for text, 4.5:1 on the canvas in both appearances (system green/orange/red failed it in light
    // mode). Box strokes and fills over the camera keep the system colours.
    static let positive = Color(light: 0x2E7D32, dark: 0x6FCF7F)
    static let warning = Color(light: 0xA45A00, dark: 0xF5A524)
    static let negative = Color(light: 0xC62828, dark: 0xFF6B6B)

    /// The colour of the n-th series, wrapping round.
    static func series(_ index: Int) -> Color {
        palette[index % palette.count]
    }
}

extension Color {
    /// One colour per appearance, each 0xRRGGBB.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }

    init(rgb: UInt32) {
        self.init(uiColor: UIColor(rgb: rgb))
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Decimal {
    /// For charts and percentages; money itself stays Decimal.
    var double: Double { NSDecimalNumber(decimal: self).doubleValue }
}

/// The page ground: flat canvas under 1 pt hairlines every 80 pt. It sits behind the scroll view, so it stays put
/// while content scrolls over it, like the site's `background-attachment: fixed`.
struct GridBackground: View {
    static let cell: CGFloat = 80

    var body: some View {
        Canvas { context, size in
            var lines = Path()
            for x in stride(from: 0, through: size.width, by: Self.cell) {
                lines.move(to: CGPoint(x: x + 0.5, y: 0))
                lines.addLine(to: CGPoint(x: x + 0.5, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: Self.cell) {
                lines.move(to: CGPoint(x: 0, y: y + 0.5))
                lines.addLine(to: CGPoint(x: size.width, y: y + 0.5))
            }
            context.stroke(lines, with: .color(Brand.hairline.opacity(0.45)), lineWidth: 1)
        }
        .background(Brand.canvas)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// kristpaulstudio.com's `.liquid-glass`: a 3 % fill, edges lit along the top and shaded along the bottom, a soft
/// shadow line, and the rim light (bright at top and bottom, clear across the middle). No blur: the live site computes
/// `backdrop-filter: none`, and a material lifted the panels to (50,49,49) against the site's (31,30,28) (measured 18 Oct).
struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = 24
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        let ink = Color(rgb: 0x141413)
        return content
            .background {
                ZStack {
                    shape.stroke(dark ? Color.black.opacity(0.4) : ink.opacity(0.04), lineWidth: 1).blur(radius: 1).offset(y: 1)
                    shape.fill(dark ? Color.white.opacity(0.03) : ink.opacity(0.03))
                }
            }
            .overlay {
                ZStack {
                    edge(shape, dark ? .white.opacity(0.22) : .white.opacity(0.7), .top)
                    edge(shape, dark ? .black.opacity(0.5) : ink.opacity(0.12), .bottom)
                    edge(shape, dark ? .white.opacity(0.06) : ink.opacity(0.05), .leading)
                    edge(shape, dark ? .black.opacity(0.15) : ink.opacity(0.05), .trailing)
                    shape.strokeBorder(Self.rim(dark ? .white : ink, edge: dark ? 0.45 : 0.25, near: dark ? 0.15 : 0.08), lineWidth: 1.4)
                }
                .allowsHitTesting(false)
            }
    }

    /// The site's ring: alpha 45 % → 15 % → 0 → 0 → 15 % → 45 % from top to bottom (the one gradient kept).
    static func rim(_ color: Color, edge: Double, near: Double) -> LinearGradient {
        LinearGradient(stops: [.init(color: color.opacity(edge), location: 0), .init(color: color.opacity(near), location: 0.2),
                               .init(color: color.opacity(0), location: 0.4), .init(color: color.opacity(0), location: 0.6),
                               .init(color: color.opacity(near), location: 0.8), .init(color: color.opacity(edge), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// One inset edge line: the panel's outline, kept only within a corner's reach of that side so it follows the curve.
    private func edge(_ shape: RoundedRectangle, _ color: Color, _ side: Edge) -> some View {
        let vertical = side == .top || side == .bottom
        let alignment: Alignment = switch side {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
        return shape.inset(by: 0.5).stroke(color, lineWidth: 1)
            .mask(alignment: alignment) {
                Rectangle().frame(width: vertical ? nil : cornerRadius, height: vertical ? cornerRadius : nil)
            }
    }
}

extension View {
    /// A content panel in the site's liquid glass.
    func card(padding: CGFloat = 16, alignment: Alignment = .leading) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: alignment)
            .modifier(LiquidGlass())
    }

    /// Forms and lists on the grid; give each section `.frostedRows()`.
    func gridList() -> some View {
        scrollContentBackground(.hidden).background(GridBackground())
    }

    /// The primary action: iOS glass filled with the button coral, so white text keeps 5:1.
    func primaryButton() -> some View {
        buttonStyle(.glassProminent).tint(Brand.buttonFill)
    }

    /// Flat card-coloured rows: glass per row would stack glass on glass.
    func frostedRows() -> some View {
        listRowBackground(Brand.card.opacity(0.85))
    }
}

/// The logo (an engraved chameleon on orange), as a rounded tile.
struct LogoTile: View {
    var size: CGFloat = 36

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            LogoTile()
            Text(verbatim: "OneShot").font(.seed(.title2)).foregroundStyle(Brand.ink)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "▲ 12% vs yesterday": a number against the same span of the period before.
struct ChangeLabel: View {
    let change: Double?
    let versus: LocalizedStringResource
    var upIsGood = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let change {
                if change != 0 {
                    Image(systemName: change > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
                        .accessibilityLabel(change > 0 ? Text("Up") : Text("Down"))
                }
                Text(abs(change), format: .percent.precision(.fractionLength(0))).font(.seed(.caption, .bold))
            } else {
                Text(verbatim: "–")
            }
            Text(versus).foregroundStyle(Brand.muted).lineLimit(1)
        }
        .font(.seed(.caption))
        .foregroundStyle(color)
    }

    private var color: Color {
        guard let change, change != 0 else { return Brand.muted }
        return (change > 0) == upIsGood ? Brand.positive : Brand.negative
    }
}

/// A product's face: its packshot cut-out (product-<sku>.png, from tools/packshots.swift), else its bundled photo,
/// else its first learned photo, else its initials on a card swatch.
struct ProductPhoto: View {
    let product: Product
    @State private var image: UIImage?
    /// A transparent packshot: shown whole on a card swatch rather than cropped to fill.
    @State private var isCutout = false
    /// The badge scales with the picture: at a fixed 12 pt it covered a 26 pt table thumbnail (19 Oct).
    @State private var side: CGFloat = 64

    var body: some View {
        // Sized by the clear base: a filled photo reports a bigger size than its slot, which put the badge off-screen.
        Color.clear
            .overlay {
                if let image, isCutout {
                    Brand.card
                    Image(uiImage: image).resizable().scaledToFit().scaleEffect(0.84)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Brand.card
                    Text(product.name.prefix(2).uppercased())
                        .font(.seed(.title2))
                        .foregroundStyle(Brand.accent)
                }
            }
            .clipped()
        .overlay(alignment: .topTrailing) {
            // The two Nori bags look the same in a thumbnail; the name truncates before "(M)".
            if let size = product.size {
                Text(verbatim: size)
                    .font(.seed(size: min(12, max(7, side * 0.2)), .heavy, relativeTo: .caption))
                    .foregroundStyle(Brand.canvas)
                    .padding(.horizontal, side < 40 ? 3 : 6)
                    .padding(.vertical, 1)
                    .background(Brand.ink, in: .capsule)
                    .padding(side < 40 ? 1 : 4)
                    .accessibilityLabel(Text("Size \(size)"))
            }
        }
        .onGeometryChange(for: CGFloat.self) { min($0.size.width, $0.size.height) } action: { side = $0 }
        .task(id: product.id) {
            let sku = product.id
            (image, isCutout) = await Task.detached(priority: .utility) {
                let cutout = Bundle.main.url(forResource: "product-\(sku)", withExtension: "png")
                let url = cutout ?? Bundle.main.url(forResource: "product-\(sku)", withExtension: "jpg") ?? CropStore.photos(for: sku).first
                return (url.flatMap { UIImage(contentsOfFile: $0.path()) }, cutout != nil)
            }.value
        }
    }
}

/// Viewfinder corners drawn over the scan zone.
struct ScanCorners: View {
    var color: Color = Brand.accent

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height, inset: CGFloat = 18, arm: CGFloat = 46
            Path { path in
                for (x, y, dx, dy) in [(inset, inset, 1.0, 1.0), (w - inset, inset, -1, 1), (inset, h - inset, 1, -1), (w - inset, h - inset, -1, -1)] {
                    path.move(to: CGPoint(x: x, y: y + dy * arm))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * arm, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// A thin line sweeping slowly down the live scan zone, so it reads as "looking" rather than a plain camera.
struct ScanSweep: View {
    @State private var atBottom = false

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Brand.accent.opacity(0.7))
                .frame(height: 2)
                .offset(y: atBottom ? geometry.size.height - 2 : 0)
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: atBottom)
        }
        .allowsHitTesting(false)
        .onAppear { atBottom = true }
    }
}
