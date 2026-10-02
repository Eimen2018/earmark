import Foundation

/// Turns digit-by-digit speech into digits: "three oh three, five five five" → "303555…".
///
/// Parakeet sometimes writes a number as digits and sometimes as words, depending on how much of
/// the sentence it has heard, and the Kept list only recognises digits. General-purpose inverse
/// normalisation (NeMo) mangles these ("one three" → "01:03"), so this handles just the case that
/// matters on calls: three or more digits read out one at a time. Shorter runs are left alone so
/// "one more time" or "two or three" stay as words.
enum SpokenNumbers {
    private static let digitWords: [String: String] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]
    private static let repeaters: [String: Int] = ["double": 2, "triple": 3]
    private static let minDigits = 3

    static func normalize(_ text: String) -> String {
        // Tokens keep their trailing separator so untouched text is rebuilt exactly.
        let pattern = try! NSRegularExpression(pattern: #"([A-Za-z]+|\d+)([\s,.\-]*)"#)
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        var i = 0
        while i < matches.count {
            // Try to grow a run of digit tokens starting here.
            var digits = ""
            var words = 0
            var j = i
            var pendingRepeat = 1
            while j < matches.count {
                let token = ns.substring(with: matches[j].range(at: 1))
                let lower = token.lowercased()
                if let times = repeaters[lower], j + 1 < matches.count,
                   digitWords[ns.substring(with: matches[j + 1].range(at: 1)).lowercased()] != nil {
                    pendingRepeat = times
                } else if let d = digitWords[lower], !(lower == "o" && digits.isEmpty) {
                    digits += String(repeating: d, count: pendingRepeat)
                    pendingRepeat = 1
                    words += 1
                } else if token.allSatisfy(\.isNumber), (words > 0 || j + 1 < matches.count) {
                    // Digits Parakeet already wrote, mixed into the spoken run.
                    digits += token
                } else {
                    break
                }
                // A sentence-ending period ends the run.
                if ns.substring(with: matches[j].range(at: 2)).contains(".") { j += 1; break }
                j += 1
            }

            if words > 0, digits.count >= minDigits {
                let start = matches[i].range.location
                let last = matches[j - 1]
                let tail = ns.substring(with: last.range(at: 2))
                out += ns.substring(with: NSRange(location: cursor, length: start - cursor))
                out += format(digits) + tail
                cursor = last.range.location + last.range.length
                i = j
            } else {
                i += 1
            }
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// US phone numbers get their usual dashes; everything else stays a plain digit string.
    private static func format(_ digits: String) -> String {
        let d = Array(digits)
        switch d.count {
        case 10: return "\(String(d[0..<3]))-\(String(d[3..<6]))-\(String(d[6..<10]))"
        case 11 where d[0] == "1": return "1-\(String(d[1..<4]))-\(String(d[4..<7]))-\(String(d[7..<11]))"
        case 7: return "\(String(d[0..<3]))-\(String(d[3..<7]))"
        default: return digits
        }
    }
}
