import Foundation

/// A destination in a synced folder that never overwrites an existing file.
public enum CloudFileName {
    public static func destination(in folder: URL, title: String, fileExtension: String, exists: (URL) -> Bool) -> URL {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\0\n\r")).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Capture" : String(cleaned.prefix(180))
        var candidate = folder.appendingPathComponent("\(name).\(fileExtension)"), index = 2
        while exists(candidate) { candidate = folder.appendingPathComponent("\(name) (\(index)).\(fileExtension)"); index += 1 }
        return candidate
    }
}
