import Foundation
import Testing

struct LocalizationTests {
    /// The app bundle ships Thai, so iOS offers it under Settings › OneShot › Language.
    @Test func appShipsThai() throws {
        let path = try #require(Bundle.main.path(forResource: "th", ofType: "lproj"))
        let thai = try #require(Bundle(path: path))
        #expect(thai.localizedString(forKey: "Pay", value: nil, table: nil) == "ชำระเงิน")
        #expect(thai.localizedString(forKey: "^[%lld item](inflect: true) to check before paying", value: nil, table: nil) == "มี %lld ชิ้นต้องตรวจก่อนชำระเงิน")
    }
}
