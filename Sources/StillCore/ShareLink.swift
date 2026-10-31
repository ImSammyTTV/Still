import Foundation

/// What's copied after an upload: the link itself, a Markdown link (an image embed for pictures), or an HTML link (an
/// <img> for pictures), as the Cloud settings ask. Windows and Linux give the same text (cloud.rs link_text).
public enum ShareLink {
    public static func text(_ link: String, title: String, image: Bool, format: String) -> String {
        switch format {
        case "markdown":
            let title = title.map { $0 == "[" || $0 == "]" ? " " : $0 }.reduce(into: "") { $0.append($1) }
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let link = link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            return image ? "![\(title)](\(link))" : "[\(title)](\(link))"
        case "html":
            func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
            return image ? "<img src=\"\(esc(link))\" alt=\"\(esc(title))\">" : "<a href=\"\(esc(link))\">\(esc(title))</a>"
        default:
            return link
        }
    }
}
