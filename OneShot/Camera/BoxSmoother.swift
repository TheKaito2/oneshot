import CoreGraphics

/// Steadies the live boxes; the lock still detects on the raw frozen frame. A box shows once the detector has seen it
/// `confirm` detections in a row. After that it keeps its label and place until a different label, or a real move
/// (overlap with what's shown below `moved`), holds for `confirm` detections in a row. It goes after `confirm` misses
/// in a row. At 15 Hz detection, 4 is about a quarter of a second (5, a third, felt slow on the iPad).
struct BoxSmoother {
    var confirm = 4
    /// Overlap with the shown box below which the item has moved; above it the change is jitter and ignored.
    var moved: CGFloat = 0.5

    private struct Track {
        var shown: Box
        var seen = 1        // detections in a row, until it shows
        var visible = false
        var changed = 0     // detections in a row that disagree with `shown`
        var missed = 0      // detections in a row without it
    }

    private var tracks: [Track] = []

    mutating func update(_ boxes: [Box]) -> [Box] {
        var free = Set(tracks.indices)
        var fresh: [Track] = []
        for box in boxes.sorted(by: { $0.confidence > $1.confidence }) {
            // The box continues the free track it overlaps most, if any overlaps enough to be the same item.
            guard let index = free.max(by: { Gallery.iou(tracks[$0].shown.rect, box.rect) < Gallery.iou(tracks[$1].shown.rect, box.rect) }),
                  Gallery.iou(tracks[index].shown.rect, box.rect) >= 0.3 else {
                fresh.append(Track(shown: box))
                continue
            }
            free.remove(index)
            tracks[index].missed = 0
            if !tracks[index].visible {
                tracks[index].shown = box
                tracks[index].seen += 1
                tracks[index].visible = tracks[index].seen >= confirm
            } else if box.label != tracks[index].shown.label || Gallery.iou(tracks[index].shown.rect, box.rect) < moved {
                tracks[index].changed += 1
                if tracks[index].changed >= confirm {
                    tracks[index].shown = box
                    tracks[index].changed = 0
                }
            } else {
                tracks[index].changed = 0
            }
        }
        for index in free {
            tracks[index].missed += 1
        }
        // An unconfirmed box that skips a detection starts its count again; a shown one lasts `confirm` misses.
        tracks = tracks.filter { $0.missed == 0 || ($0.visible && $0.missed < confirm) } + fresh
        return tracks.filter(\.visible).map(\.shown)
    }
}
