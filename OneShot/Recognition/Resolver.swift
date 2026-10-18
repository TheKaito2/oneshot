/// Who named a region.
enum Source: Equatable {
    case detector, gallery, both, cashier
}

enum Verdict: Equatable {
    /// Goes on the bill.
    case sure(sku: String, by: Source)
    /// Yellow: never priced until the cashier picks. Best candidates first, at most 3.
    case unsure(candidates: [String])

    var sku: String? {
        if case .sure(let sku, _) = self { sku } else { nil }
    }
}

/// "Both vote": the trained detector (L1) and the few-shot gallery (L2) each name a region.
/// Agree, or only one is sure: green. Both sure but different, or neither sure: yellow.
struct Resolver {
    /// Measured 18 Oct with tools/grade.py on detector v3 (NMS IoU 0.45, floor 0.25), detector vote only, held-out
    /// photos. Exam (42 mixed photos, 339 units): 0 wrong prices from 0.65 up; at 0.7, 338 right, 1 Mars yellow,
    /// 41/42 exact bills. Unknown items (white phone, bottle, an object at the frame edge; 4 photos): 1 wrong up to
    /// 0.65, 0 from 0.7. Nori pairs: 8/8 throughout. 0.7 is the lowest value with no wrong price anywhere.
    var detectorSure: Float = 0.7
    /// Measured on the iPad Air, 18 Oct (6 locks, 2 quick-added items): tight crops of the item scored
    /// 0.837–0.866, everything else ≤ 0.717 once containers are dropped. Midpoint.
    var gallerySure: Float = 0.78

    /// Both guess lists hold catalog SKUs only, best first.
    func verdict(detector: [Guess], gallery: [Guess]) -> Verdict {
        // Two strong labels for one item (overlapping boxes merged, e.g. two Lay's flavours): the detector can't decide.
        let detectorTorn = detector.count > 1 && detector[1].confidence >= detectorSure
        let l1 = detectorTorn ? nil : detector.first.flatMap { $0.confidence >= detectorSure ? $0.label : nil }
        let l2 = gallery.first.flatMap { $0.confidence >= gallerySure ? $0.label : nil }
        switch (l1, l2) {
        case let (a?, b?) where a == b: return .sure(sku: a, by: .both)
        case let (a?, nil): return .sure(sku: a, by: .detector)
        case let (nil, b?): return .sure(sku: b, by: .gallery)
        default: return .unsure(candidates: Self.candidates(detector, gallery))
        }
    }

    /// Interleaves both lists so each voter's favourite shows up front.
    static func candidates(_ detector: [Guess], _ gallery: [Guess]) -> [String] {
        var seen = Set<String>()
        let interleaved = (0..<max(detector.count, gallery.count)).flatMap { index in
            [detector.indices.contains(index) ? detector[index] : nil,
             gallery.indices.contains(index) ? gallery[index] : nil].compactMap { $0 }
        }
        return Array(interleaved.map(\.label).filter { seen.insert($0).inserted }.prefix(3))
    }
}
