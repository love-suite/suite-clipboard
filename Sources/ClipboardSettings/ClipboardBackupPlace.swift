import Foundation
import SystemConfiguration

/// Where the history's iCloud Drive backup goes, as the Clipboard tab of Settings shows it: one folder per
/// Mac in `iCloud Drive/Explorer/Clipboard`.
public enum ClipboardBackupPlace {
    /// iCloud Drive's folder, when iCloud Drive is on.
    public static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue ? url : nil
    }

    /// The folder holding each Mac's backup.
    public static var root: URL? {
        iCloudDrive?.appendingPathComponent("Explorer/Clipboard", isDirectory: true)
    }

    /// This Mac's name (System Settings › General › Sharing), as a folder name.
    public static var machineName: String {
        let computer: String = SCDynamicStoreCopyComputerName(nil, nil).map { $0 as String } ?? "Mac"
        let name = computer.map { "/:".contains($0) ? "-" : $0 }
        let trimmed = String(name).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".")))
        return trimmed.isEmpty ? "Mac" : trimmed
    }
}
