import Foundation
import StillCore

/// Saves into the iCloud Drive folder, which macOS keeps in sync. Apple offers no share links without a paid
/// developer account, so unlike the other destinations this saves the file and has no link to copy.
enum ICloudDrive {
    private static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    static var available: Bool { FileManager.default.fileExists(atPath: root.path) }
    @discardableResult static func save(_ file: URL, title: String) throws -> URL {
        let folder = root.appendingPathComponent("Still", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = CloudFileName.destination(in: folder, title: title, fileExtension: file.pathExtension) { FileManager.default.fileExists(atPath: $0.path) }
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }
}
