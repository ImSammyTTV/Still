import Foundation

/// The name a new capture gets from Settings → Screenshots → File name. The Windows and Linux app follow the same
/// rule, so a pattern names files the same everywhere. Tokens: {date} 2026-10-31, {time} 13.05.22, {type}
/// Screenshot or Recording, {width} and {height} in pixels (empty when not known), {n} its number among today's
/// captures. Characters no file system accepts become "-", and a pattern that leaves nothing falls back to the default.
public enum CaptureNaming {
    public static let defaultPattern = "{type} {date} at {time}"

    public static func name(pattern: String, isVideo: Bool = false, date: Date = Date(), width: Int = 0, height: Int = 0, number: Int = 1, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let two = { (value: Int?) in String(format: "%02d", value ?? 0) }
        let fill = { (text: String) in
            text.replacingOccurrences(of: "{date}", with: "\(parts.year ?? 0)-\(two(parts.month))-\(two(parts.day))")
                .replacingOccurrences(of: "{time}", with: "\(two(parts.hour)).\(two(parts.minute)).\(two(parts.second))")
                .replacingOccurrences(of: "{type}", with: isVideo ? "Recording" : "Screenshot")
                .replacingOccurrences(of: "{width}", with: width > 0 ? String(width) : "")
                .replacingOccurrences(of: "{height}", with: height > 0 ? String(height) : "")
                .replacingOccurrences(of: "{n}", with: String(number))
        }
        let clean = { (text: String) in
            String(text.map { "\\/:*?\"<>|\n\r\t".contains($0) ? "-" : $0 }).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let name = String(clean(fill(pattern)).prefix(180))
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "-. ")).isEmpty ? clean(fill(defaultPattern)) : name
    }
}
