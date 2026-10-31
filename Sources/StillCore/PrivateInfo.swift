import Foundation
import Vision
import CoreGraphics

/// Finds the private details in recognised text (email addresses, card numbers, keys and tokens, IP addresses and
/// phone numbers) so the editor can cover them in one go. Windows and Linux follow the same rules (shared/private.js)
/// and share the test cases.
public enum PrivateInfo {
    public struct Hit: Equatable {
        public var kind: String
        public var range: NSRange
    }

    private static let octet = "(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)"
    /// In order of priority: a part of the text claimed by one kind isn't looked at again by a later one.
    private static let rules: [(String, NSRegularExpression)] = [
        ("email", "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}"),
        ("key", "\\b(?:[sprk]k_(?:live|test)_[A-Za-z0-9]{8,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{5,})"),
        ("key", "[A-Za-z0-9_-]{24,}"),
        ("card", "\\b(?:\\d[ -]?){12,18}\\d\\b"),
        ("ip", "\\b(?:\(octet)\\.){3}\(octet)\\b"),
        ("phone", "(?:\\+\\d{1,3}[ .-]?)?(?:\\(\\d{2,4}\\)[ .-]?)?\\d{2,4}(?:[ .-]\\d{2,4}){1,4}|\\+\\d{9,15}"),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// The card-number checksum, which rules out most long numbers that only look like cards.
    public static func luhn(_ number: String) -> Bool {
        var sum = 0
        for (i, character) in number.reversed().enumerated() {
            guard var d = character.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// Whether a match really is one: a long run of letters and digits counts as a key only when it mixes upper case,
    /// lower case and digits, as generated secrets do and words and file names rarely do.
    private static func accepts(_ kind: String, _ text: String, rule: Int) -> Bool {
        let digits = text.filter(\.isASCII).filter(\.isNumber)
        switch kind {
        case "key" where rule == 2: return text.contains(where: \.isLowercase) && text.contains(where: \.isUppercase) && text.contains(where: \.isNumber)
        case "card": return (13...19).contains(digits.count) && luhn(String(digits))
        case "phone": return (9...15).contains(digits.count)
        default: return true
        }
    }

    /// Every private detail in `text`, in reading order, as UTF-16 ranges.
    public static func find(_ text: String) -> [Hit] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var found: [Hit] = []
        for (rule, (kind, pattern)) in rules.enumerated() {
            for match in pattern.matches(in: text, range: whole) {
                let range = match.range, piece = (text as NSString).substring(with: range)
                guard accepts(kind, piece, rule: rule), !found.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { continue }
                found.append(Hit(kind: kind, range: range))
            }
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// Boxes to cover on `image`, in its pixels from the top left, with a little room so no edge of a letter shows.
    public static func boxes(in image: CGImage, padding: CGFloat = 3) throws -> [CGRect] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        var boxes: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for hit in find(text) {
                guard let range = Range(hit.range, in: text), let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                boxes.append(CGRect(x: box.minX * width - padding, y: (1 - box.maxY) * height - padding, width: box.width * width + padding * 2, height: box.height * height + padding * 2))
            }
        }
        return boxes
    }
}
