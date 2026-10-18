import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Thai PromptPay as an EMVCo merchant-presented QR. With an amount it is dynamic (tag 01 = "12"), so the
/// customer's bank app opens with the amount filled in and locked. Field order follows dtinth/promptpay-qr,
/// whose published vectors the tests check.
enum PromptPay {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private static let promptPayAID = "A000000677010111"

    /// `target`: a Thai mobile (0xx-xxx-xxxx or +66…), a 13-digit national/tax ID, or a 15-digit e-wallet ID.
    static func payload(target: String, amount: Decimal?) throws -> String {
        let account = try merchantAccount(target)
        var fields = [
            field("00", "01"),
            field("01", amount == nil ? "11" : "12"),
            field("29", field("00", promptPayAID) + field(account.tag, account.value)),
            field("58", "TH"),
            field("53", "764"),
        ]
        if let amount {
            guard amount > 0 else { throw Failure(errorDescription: "The amount must be above zero.") }
            fields.append(field("54", format(amount)))
        }
        // The CRC covers its own tag and length.
        let body = fields.joined() + "6304"
        return body + String(format: "%04X", crc16(body))
    }

    static func isValidTarget(_ target: String) -> Bool { (try? merchantAccount(target)) != nil }

    /// Long enough to judge: a "not valid" warning after 3 typed digits read as a mistake that hadn't happened yet.
    static func looksFinished(_ target: String) -> Bool { target.filter(\.isNumber).count >= 10 }

    private static func merchantAccount(_ target: String) throws -> (tag: String, value: String) {
        let digits = String(target.unicodeScalars.filter { ("0"..."9").contains($0) })
        switch digits.count {
        case 15: return ("03", digits)
        case 13: return ("02", digits)
        case 10 where digits.hasPrefix("0"), 11 where digits.hasPrefix("66"):
            let international = digits.hasPrefix("0") ? "66" + digits.dropFirst() : digits
            return ("01", String(repeating: "0", count: 13 - international.count) + international)
        default:
            throw Failure(errorDescription: "Not a Thai mobile number, 13-digit ID or 15-digit e-wallet ID.")
        }
    }

    private static func field(_ tag: String, _ value: String) -> String {
        tag + String(format: "%02d", value.count) + value
    }

    private static func format(_ amount: Decimal) -> String {
        amount.formatted(.number.precision(.fractionLength(2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// CRC-16/CCITT-FALSE: polynomial 0x1021, initial 0xFFFF, no reflection, no final XOR.
    static func crc16(_ text: String) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in text.utf8 {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// Crisp QR image, scaled up without smoothing.
    static func qrImage(_ payload: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum PaymentMethod: String, Codable {
    case promptPay, cash
}

/// Cash at the counter, Loyverse-style: one-tap amounts, then the change.
enum Cash {
    private static let notes: [Decimal] = [20, 50, 100, 500, 1000]

    /// The exact total, then the next amount payable in each Thai banknote, smallest first (at most 5).
    static func suggestions(for total: Decimal) -> [Decimal] {
        var amounts = [rounded(total, scale: 2, .plain)]
        for note in notes {
            let next = rounded(total / note, scale: 0, .up) * note
            if next > total, !amounts.contains(next) { amounts.append(next) }
        }
        return Array(amounts.prefix(5))
    }

    private static func rounded(_ value: Decimal, scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var result = Decimal(), input = value
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }
}

enum ThaiVoice {
    /// What the iPad says at payment: "ทั้งหมด 59 บาท 90 สตางค์". Numerals are read as Thai words by the voice.
    static func totalPhrase(_ total: Decimal) -> String {
        "ทั้งหมด " + baht(total)
    }

    /// After cash: "รับ 100 บาท ทอน 40 บาท 10 สตางค์", or "รับ 60 บาท พอดี" when no change is due.
    static func changePhrase(received: Decimal, total: Decimal) -> String {
        let change = received - total
        return change > 0 ? "รับ \(baht(received)) ทอน \(baht(change))" : "รับ \(baht(received)) พอดี"
    }

    private static func baht(_ amount: Decimal) -> String {
        var rounded = Decimal(), value = amount
        NSDecimalRound(&rounded, &value, 2, .plain)
        let satangTotal = NSDecimalNumber(decimal: rounded * 100).intValue
        let baht = satangTotal / 100, satang = satangTotal % 100
        return satang == 0 ? "\(baht) บาท" : "\(baht) บาท \(satang) สตางค์"
    }
}
