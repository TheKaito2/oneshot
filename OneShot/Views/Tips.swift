import SwiftUI
import TipKit

// First-run guidance for a judge (or cashier) picking the iPad up cold. Settings › Show tips again resets them.

struct LockTip: Tip {
    var title: Text { Text("Hold over the items, then tap Ring up") }
    var message: Text? { Text("One photo rings up the whole pile.") }
    var image: Image? { Image(systemName: "bolt.fill") }
}

struct QuickAddTip: Tip {
    var title: Text { Text("Teach a new product") }
    var message: Text? { Text("8 photos and a price. No retraining.") }
    var image: Image? { Image(systemName: "plus") }
}

struct UnsureTip: Tip {
    var title: Text { Text("Yellow means not sure") }
    var message: Text? { Text("Tap it and pick the right item. OneShot never guesses a price.") }
    var image: Image? { Image(systemName: "questionmark.circle") }
}
