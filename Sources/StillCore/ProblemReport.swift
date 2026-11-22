import Foundation

/// The parts of Report a Problem that don't need the Mac's screens or windows: the lines Still's own log keeps, when
/// that log starts a fresh file, which settings are safe to show, and the issue page it opens. Kept here so they can
/// be tested, and so nothing private slips into a report someone shares.
public enum ProblemReport {
    /// The log moves to still.log.1 past this size, so it never grows without end; the newest lines are always kept.
    public static let logLimit = 1_000_000
    /// How many of the latest log lines a report carries.
    public static let reportLines = 400
    public static let issueTitle = "Problem: "

    // MARK: Log

    /// One log entry: a timestamp, then the message on a single line so every entry stays one line long.
    public static func logLine(_ message: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let flat = message.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " | ")
        return "\(formatter.string(from: date)) \(flat)\n"
    }

    /// Whether adding `adding` bytes would take the log past `limit`, so it should move aside first. An empty log is
    /// never moved aside, even for one very long entry, so a single line can't empty the history.
    public static func shouldRotate(currentSize: Int, adding: Int, limit: Int = logLimit) -> Bool {
        currentSize > 0 && currentSize + adding > limit
    }

    /// The last `count` non-empty lines of `text`, oldest first.
    public static func lastLines(_ text: String, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Array(lines.suffix(count))
    }

    // MARK: Settings

    /// Name parts that mean a setting holds a password, key or token. Its value never goes in a report.
    static let secretParts: Set<String> = ["key", "apikey", "token", "tokens", "secret", "secrets", "password", "passcode", "passphrase", "credential", "credentials", "auth", "authorization", "bearer", "cookie", "signature"]

    /// Splits a setting's name into lowercase parts: "serviceAPIKey" → service, api, key; "access_token" → access, token.
    public static func nameParts(_ name: String) -> [String] {
        var parts: [String] = [], current = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else { if !current.isEmpty { parts.append(current) }; current = ""; continue }
            if character.isUppercase, !current.isEmpty, let last = current.last {
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                // A new word starts at "aB" ("serviceKey"), or at the last capital of a run followed by lowercase ("APIKey").
                if last.isLowercase || last.isNumber || (last.isUppercase && nextIsLower) { parts.append(current); current = "" }
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }

    /// True when a setting's name says it's a secret ("apiKey", "service_api_key", "authToken", "password").
    /// "keysSize" and "recordingKeys" are about keystrokes shown in recordings, so they aren't.
    public static func isSecretName(_ name: String) -> Bool {
        let parts = nameParts(name)
        if parts.contains(where: { secretParts.contains($0) }) { return true }
        let joined = parts.joined()
        return ["apikey", "accesstoken", "password", "secret", "credential"].contains(where: { joined.contains($0) })
    }

    /// True when a value looks like a key or token whatever its setting is called: a long run of letters and digits
    /// with no spaces, or one of the well-known key prefixes.
    public static func looksLikeSecretValue(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("sk-") || text.hasPrefix("AIza") || text.hasPrefix("ghp_") || text.hasPrefix("xox") { return text.count >= 16 }
        guard text.count >= 24, !text.contains(where: { $0.isWhitespace }), !text.contains("/") else { return false }
        return text.contains(where: { $0.isLetter }) && text.contains(where: { $0.isNumber })
    }

    /// Settings as "name: value" lines in name order, safe to share. A secret's value is replaced with "(removed)", and
    /// names in `privateText` (things you typed, folders that show your user name) only say whether they're set.
    public static func settingLines(_ settings: [String: String], privateText: Set<String> = []) -> [String] {
        settings.keys.sorted().map { name in
            let value = settings[name] ?? ""
            if isSecretName(name) || looksLikeSecretValue(value) { return "\(name): (removed)" }
            if privateText.contains(name) { return "\(name): \(value.isEmpty ? "(empty)" : "(set, left out)")" }
            return "\(name): \(value)"
        }
    }

    /// Replaces the home folder in paths in `text` with "~" so a report doesn't carry your user name in every path.
    /// Only whole folder names match, so /Users/sam doesn't change /Users/samantha.
    public static func hidingHome(_ text: String, home: String) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard trimmed.count > 1 else { return text }
        return text.replacingOccurrences(of: trimmed + "/", with: "~/")
    }

    // MARK: Report

    /// What a report says about this Mac and Still. Collected by the app; turned into text here.
    public struct Facts: Sendable {
        public var version: String
        public var build: String
        public var macOS: String
        public var model: String
        public var displays: [String]
        public var screenRecordingAllowed: Bool
        public var settings: [String]
        public var historyCount: Int
        public var logLines: [String]
        public var created: Date
        public init(version: String, build: String, macOS: String, model: String, displays: [String], screenRecordingAllowed: Bool, settings: [String], historyCount: Int, logLines: [String], created: Date) {
            self.version = version; self.build = build; self.macOS = macOS; self.model = model; self.displays = displays
            self.screenRecordingAllowed = screenRecordingAllowed; self.settings = settings; self.historyCount = historyCount
            self.logLines = logLines; self.created = created
        }
    }

    /// The report's file name, such as "Still problem report 2026-11-22 at 14.05.09.txt". Dots, not colons, in the
    /// time, because Finder can't show a colon in a name.
    public static func fileName(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Still problem report \(formatter.string(from: date)).txt"
    }

    /// The whole plain-text report.
    public static func text(_ facts: Facts, timeZone: TimeZone = .current) -> String {
        let stamp = logLine("", date: facts.created, timeZone: timeZone).trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = [
            "Still problem report",
            "Made \(stamp). It stays on your Mac until you attach it somewhere; read it over first if you like.",
            "",
            "== Still and this Mac ==",
            "Still \(facts.version) (build \(facts.build))",
            "macOS \(facts.macOS)",
            "Mac model: \(facts.model.isEmpty ? "unknown" : facts.model)",
            "Screen recording permission: \(facts.screenRecordingAllowed ? "allowed" : "not allowed")",
            "Items in Capture History: \(facts.historyCount)",
            "",
            "== Displays =="
        ]
        lines += facts.displays.isEmpty ? ["(none found)"] : facts.displays
        lines += ["", "== Settings (keys and typed text left out) =="] + facts.settings
        lines += ["", "== Recent log (last \(facts.logLines.count) lines) =="]
        lines += facts.logLines.isEmpty ? ["(nothing logged yet)"] : facts.logLines
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Issue page

    /// The body the new issue page starts with. The report itself isn't in it: the log can be long, and it's yours to
    /// attach or not.
    public static func issueBody(version: String, build: String, macOS: String) -> String {
        """
        ### What happened


        ### What you expected


        ### Steps to make it happen
        1.
        2.
        3.

        ### System
        Still \(version) (build \(build))
        macOS \(macOS)

        A problem report was saved to the Desktop. Drag it here if you're happy to share it.
        """
    }

    /// Characters left as they are in a URL query value (RFC 3986 unreserved); everything else is percent-encoded,
    /// so "&", "=", "+", "#" and line breaks in the text can't break the link.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The new issue page for `repository` ("owner/name") with the title and body filled in.
    public static func issueURL(repository: String, version: String, build: String, macOS: String) -> URL? {
        let body = issueBody(version: version, build: build, macOS: macOS)
        return URL(string: "https://github.com/\(repository)/issues/new?title=\(percentEncoded(issueTitle))&body=\(percentEncoded(body))")
    }
}
