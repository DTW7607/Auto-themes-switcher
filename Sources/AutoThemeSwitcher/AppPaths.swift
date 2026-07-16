import Foundation

struct AppPaths: Sendable {
    let applicationSupportDirectory: URL
    let backupDirectory: URL
    let vscodeSettings: URL
    let ghosttyConfiguration: URL
    let ghosttyExecutable: URL

    static func currentUser(fileManager: FileManager = .default) -> AppPaths {
        let home = fileManager.homeDirectoryForCurrentUser
        let support = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("dev.dtw.AutoThemeSwitcher", isDirectory: true)

        return AppPaths(
            applicationSupportDirectory: support,
            backupDirectory: support.appendingPathComponent("Backups", isDirectory: true),
            vscodeSettings: home.appendingPathComponent(
                "Library/Application Support/Code/User/settings.json",
                isDirectory: false
            ),
            ghosttyConfiguration: home.appendingPathComponent(
                "Library/Application Support/com.mitchellh.ghostty/config.ghostty",
                isDirectory: false
            ),
            ghosttyExecutable: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        )
    }

    func prepareOwnedDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
    }
}
