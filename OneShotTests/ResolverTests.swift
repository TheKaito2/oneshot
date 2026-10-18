import Testing
@testable import OneShot

struct ResolverTests {
    let resolver = Resolver(detectorSure: 0.5, gallerySure: 0.8)

    private func g(_ label: String, _ confidence: Float) -> Guess { Guess(label: label, confidence: confidence) }

    @Test func agreeingVotersAreGreen() {
        #expect(resolver.verdict(detector: [g("lays", 0.9)], gallery: [g("lays", 0.95)]) == .sure(sku: "lays", by: .both))
    }

    @Test func sureDetectorWinsOverUnsureGallery() {
        #expect(resolver.verdict(detector: [g("lays", 0.9)], gallery: [g("pocky", 0.6)]) == .sure(sku: "lays", by: .detector))
        #expect(resolver.verdict(detector: [g("lays", 0.9)], gallery: []) == .sure(sku: "lays", by: .detector))
    }

    @Test func sureGalleryNamesQuickAddedItems() {
        // A quick-added SKU has no detector class yet, so only the gallery can name it.
        #expect(resolver.verdict(detector: [g("lays", 0.2)], gallery: [g("judge-item", 0.9)]) == .sure(sku: "judge-item", by: .gallery))
        #expect(resolver.verdict(detector: [], gallery: [g("judge-item", 0.9)]) == .sure(sku: "judge-item", by: .gallery))
    }

    @Test func confidentDisagreementIsYellow() {
        #expect(resolver.verdict(detector: [g("lays-green", 0.9), g("lays-blue", 0.05)], gallery: [g("lays-blue", 0.9)])
                == .unsure(candidates: ["lays-green", "lays-blue"]))
    }

    @Test func bothWeakIsYellowWithInterleavedCandidates() {
        let verdict = resolver.verdict(detector: [g("a", 0.3), g("b", 0.2), g("c", 0.1)], gallery: [g("x", 0.5), g("a", 0.4)])
        #expect(verdict == .unsure(candidates: ["a", "x", "b"]))
        #expect(resolver.verdict(detector: [], gallery: []) == .unsure(candidates: []))
    }

    @Test func twoStrongLabelsForOneItemIsYellow() {
        #expect(resolver.verdict(detector: [g("cell phone", 0.86), g("remote", 0.63)], gallery: [])
                == .unsure(candidates: ["cell phone", "remote"]))
    }

    @Test func thresholdIsInclusive() {
        #expect(resolver.verdict(detector: [g("lays", 0.5)], gallery: []) == .sure(sku: "lays", by: .detector))
    }
}
