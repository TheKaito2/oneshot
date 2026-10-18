import Foundation
import Testing
@testable import OneShot

/// Expected strings are copied from dtinth/promptpay-qr `index.test.js` (independent of this code).
struct PromptPayTests {
    @Test(arguments: [
        ("0801234567", "00020101021129370016A000000677010111011300668012345675802TH530376463046197"),
        ("080-123-4567", "00020101021129370016A000000677010111011300668012345675802TH530376463046197"),
        ("+66-89-123-4567", "00020101021129370016A000000677010111011300668912345675802TH5303764630429C1"),
        ("1111111111111", "00020101021129370016A000000677010111021311111111111115802TH530376463047B5A"),
        ("1-1111-11111-11-1", "00020101021129370016A000000677010111021311111111111115802TH530376463047B5A"),
        ("0123456789012", "00020101021129370016A000000677010111021301234567890125802TH530376463040CBD"),
        ("012345678901234", "00020101021129390016A00000067701011103150123456789012345802TH530376463049781"),
    ])
    func staticPayloadsMatchDtinth(target: String, expected: String) throws {
        #expect(try PromptPay.payload(target: target, amount: nil) == expected)
    }

    @Test func amountPayloadMatchesDtinth() throws {
        #expect(try PromptPay.payload(target: "000-000-0000", amount: Decimal(string: "4.22")!)
                == "00020101021229370016A000000677010111011300660000000005802TH530376454044.226304E469")
    }

    @Test func crcMatchesTheStandardCheckValue() {
        // CRC-16/CCITT-FALSE of "123456789" is 0x29B1 by definition.
        #expect(PromptPay.crc16("123456789") == 0x29B1)
    }

    @Test func wholeBahtAmountsKeepTwoDecimals() throws {
        #expect(try PromptPay.payload(target: "0801234567", amount: 20).contains("540520.00"))
    }

    @Test func rejectsBadInput() {
        #expect(throws: PromptPay.Failure.self) { try PromptPay.payload(target: "12345", amount: nil) }
        #expect(throws: PromptPay.Failure.self) { try PromptPay.payload(target: "0801234567", amount: 0) }
        #expect(!PromptPay.isValidTarget("1234"))
        #expect(PromptPay.isValidTarget("081-234-5678"))
    }

    @Test func thaiPhraseReadsBahtAndSatang() {
        #expect(ThaiVoice.totalPhrase(Decimal(string: "59.9")!) == "ทั้งหมด 59 บาท 90 สตางค์")
        #expect(ThaiVoice.totalPhrase(120) == "ทั้งหมด 120 บาท")
        #expect(ThaiVoice.totalPhrase(Decimal(string: "12.05")!) == "ทั้งหมด 12 บาท 5 สตางค์")
    }
}

struct CashTests {
    @Test func suggestsExactThenNextBanknotes() {
        #expect(Cash.suggestions(for: Decimal(string: "59.9")!) == [Decimal(string: "59.9")!, 60, 100, 500, 1000])
        #expect(Cash.suggestions(for: 120) == [120, 150, 200, 500, 1000])
        #expect(Cash.suggestions(for: 4990) == [4990, 5000])
    }

    @Test func changeIsSpokenInThai() {
        #expect(ThaiVoice.changePhrase(received: 100, total: Decimal(string: "59.9")!) == "รับ 100 บาท ทอน 40 บาท 10 สตางค์")
        #expect(ThaiVoice.changePhrase(received: 60, total: 60) == "รับ 60 บาท พอดี")
    }
}
