import Foundation

/// A detail worth holding on to: a phone number, address, date, ID…
struct Detail: Hashable {
    let kind: String
    let range: Range<String.Index>
}

/// Finds details in a caption line. Apple's data detectors handle phones, addresses and dates;
/// a few patterns cover what they miss (emails, money, member IDs and other long numbers).
enum DetailFinder {
    private static let detector = try! NSDataDetector(
        types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue)

    private static let patterns: [(kind: String, regex: NSRegularExpression)] = [
        ("Email", #"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#),
        ("Amount", #"\$\s?\d[\d,]*(?:\.\d{1,2})?|\b\d[\d,]*(?:\.\d{1,2})?\s?(?:dollars|euros|pounds)\b"#),
        ("Number", #"\b\d(?:[\d,.-]*\d){2,}\b"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1, options: .caseInsensitive)) }

    static func find(in text: String) -> [Detail] {
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(kind: String, range: NSRange, priority: Int)] = []

        for match in detector.matches(in: text, range: whole) {
            switch match.resultType {
            case .phoneNumber: found.append(("Phone", match.range, 0))
            case .address: found.append(("Address", match.range, 0))
            case .date: found.append(("Date", match.range, 1))
            default: break
            }
        }
        for (i, pattern) in patterns.enumerated() {
            for match in pattern.regex.matches(in: text, range: whole) {
                found.append((pattern.kind, match.range, 2 + i))
            }
        }

        // Longest match wins where they overlap; ties go to the more specific kind.
        found.sort { a, b in
            a.range.location != b.range.location ? a.range.location < b.range.location
                : a.range.length != b.range.length ? a.range.length > b.range.length
                : a.priority < b.priority
        }
        var details: [Detail] = []
        var end = 0
        for item in found where item.range.location >= end {
            guard let range = Range(item.range, in: text) else { continue }
            details.append(Detail(kind: item.kind, range: range))
            end = item.range.location + item.range.length
        }
        return details
    }
}
