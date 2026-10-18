import CoreGraphics
import UIKit

/// Stand-in for the camera when presenting from the simulator or without the snacks: table photos from the test set
/// (Resources/Demo/demo-<n>.jpg, never trained on), shown in the scan zone and rung up by the same pipeline as a lock.
/// 1: all twelve products spread out · 2: six, both Nori bags · 3: three Lay's · 4: four Lay's.
enum DemoFeed {
    static let count = 4

    /// Frame `index` (wrapping), upright.
    static func frame(_ index: Int) -> CGImage? {
        let name = "demo-\(index % count + 1)"
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else {
            print("missing \(name).jpg")
            return nil
        }
        return UIImage(contentsOfFile: url.path())?.cgImage
    }
}
