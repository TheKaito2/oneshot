import Testing
import UIKit
@testable import OneShot

/// The bundled LINE Seed faces must register (UIAppFonts) under the names `Font.seed` asks for;
/// a missing face silently falls back to the system font.
struct FontTests {
    @Test(arguments: [Seed.Weight.regular, .bold, .extraBold, .heavy])
    func everyWeightResolves(_ weight: Seed.Weight) {
        #expect(UIFont(name: weight.postScriptName, size: 17) != nil)
    }

    @Test func textStylesFollowTheHIGScale() {
        #expect(Seed.size(.largeTitle) == 34)
        #expect(Seed.size(.body) == 17)
        #expect(Seed.size(.caption2) == 12)   // held at the 12 pt floor
        #expect(Seed.weight(for: .title3) == .bold)
        #expect(Seed.weight(for: .subheadline) == .regular)
    }
}
