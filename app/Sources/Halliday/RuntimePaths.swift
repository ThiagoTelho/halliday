import Foundation

enum RuntimePaths {
    /// Development bundles can keep their bridge and logs separate from an installed release.
    static let folderName = Bundle.main.object(forInfoDictionaryKey: "HallidayRuntimeFolderName") as? String ?? "Halliday"
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(folderName, isDirectory: true)
    static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(folderName).log")
}
