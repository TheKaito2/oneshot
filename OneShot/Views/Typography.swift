import SwiftUI
import UIKit

/// OneShot's type: LINE Seed Sans TH, the Young iOS Developer Hackathon's typeface, for English and Thai alike
/// (LINE's "App" build, © LY Corporation, SIL OFL 1.1, licence in Resources/Fonts).
///
/// Hierarchy rules, from Apple's HIG (Typography) and Refactoring UI:
/// - One page title per screen, at most three levels inside a card.
/// - Build each level from size, weight and colour together; de-emphasise secondary text with colour
///   (ink → body → muted), never by shrinking it under 12 pt.
/// - Sizes are the HIG text styles at the default text size and scale with Dynamic Type; no light weights.
/// - Spaced capitals for eyebrows (+0.125 em, as kristpaulstudio.com does), titles set a touch tight.
/// - The family has Regular, Bold, ExtraBold and Heavy only (no Medium or Semibold), and no tabular figures,
///   so emphasis steps straight to Bold and numeric columns line up by right-aligning.
enum Seed {
    enum Weight: Int {
        case regular, bold, extraBold, heavy

        var postScriptName: String {
            ["LINESeedSansTHApp-Regular", "LINESeedSansTHApp-Bold", "LINESeedSansTHApp-ExtraBold", "LINESeedSansTHApp-Heavy"][rawValue]
        }

        /// The HIG asks custom fonts to honour Bold Text: every weight steps up one.
        var resolved: Weight {
            UIAccessibility.isBoldTextEnabled ? Weight(rawValue: min(rawValue + 1, Weight.heavy.rawValue))! : self
        }
    }

    /// HIG default sizes ("Large", the default text size). Caption 2 is held at 12, the floor set above.
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        default: 12
        }
    }

    /// Titles and headlines are bold, everything else regular.
    static func weight(for style: Font.TextStyle) -> Weight {
        switch style {
        case .largeTitle, .title, .title2, .title3, .headline: .bold
        default: .regular
        }
    }

    /// Letter-spacing for spaced capitals. Thai has no capitals and isn't letter-spaced: tracking pulls a word apart.
    static var capsTracking: CGFloat {
        Bundle.main.preferredLocalizations.first == "th" ? 0 : 1.5
    }

    static func uiFont(_ style: Font.TextStyle, _ weight: Weight? = nil) -> UIFont {
        UIFont(name: (weight ?? Self.weight(for: style)).resolved.postScriptName, size: size(style))
            ?? .systemFont(ofSize: size(style))
    }
}

extension Font {
    /// A HIG text style in LINE Seed, scaling with Dynamic Type.
    static func seed(_ style: Font.TextStyle, _ weight: Seed.Weight? = nil) -> Font {
        .custom((weight ?? Seed.weight(for: style)).resolved.postScriptName, size: Seed.size(style), relativeTo: style)
    }

    /// Display sizes (hero, totals, KPI values), scaling with Dynamic Type like `style`.
    static func seed(size: CGFloat, _ weight: Seed.Weight, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .custom(weight.resolved.postScriptName, size: size, relativeTo: style)
    }
}

extension View {
    /// kristpaulstudio.com's eyebrow: small bold capitals, widely spaced, muted.
    func eyebrow() -> some View {
        font(.seed(.caption, .bold)).textCase(.uppercase).tracking(Seed.capsTracking).foregroundStyle(Brand.muted)
    }
}

/// kristpaulstudio.com's section marker: "02 / 03   SALES" on a long hairline that ends in an accent dot,
/// with an optional line under it saying what the numbers are compared with.
struct SectionMarker: View {
    let index: Int
    let total: Int
    let title: LocalizedStringKey
    var subtitle: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text(verbatim: String(format: "%02d / %02d", index, total)).monospacedDigit()
                Text(title).textCase(.uppercase)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                Circle().fill(Brand.accent).frame(width: 6, height: 6)
            }
            .font(.seed(.caption, .bold))
            .tracking(Seed.capsTracking)
            .foregroundStyle(Brand.muted)
            if let subtitle {
                Text(subtitle).font(.seed(.subheadline)).foregroundStyle(Brand.body)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The short accent bar kristpaulstudio.com draws under a display headline.
struct AccentRule: View {
    var body: some View {
        Capsule().fill(Brand.accent).frame(width: 32, height: 3)
    }
}

/// Seed in the UIKit chrome SwiftUI doesn't reach: navigation titles, segmented pickers, tab items.
enum SeedAppearance {
    /// Title attributes only: the bars keep iOS 26's own glass and scroll-edge treatment.
    static func apply() {
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: Seed.uiFont(.largeTitle)]
        UINavigationBar.appearance().titleTextAttributes = [.font: Seed.uiFont(.headline)]
        UISegmentedControl.appearance().setTitleTextAttributes([.font: Seed.uiFont(.subheadline, .bold)], for: .normal)
        UITabBarItem.appearance().setTitleTextAttributes([.font: Seed.uiFont(.subheadline, .bold)], for: .normal)
    }
}
