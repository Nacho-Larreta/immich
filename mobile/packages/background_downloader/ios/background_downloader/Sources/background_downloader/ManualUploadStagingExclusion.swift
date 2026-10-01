import Foundation

final class ManualUploadStagingExclusion {
    private enum PreparationError: Error {
        case unavailableApplicationSupport
        case unauthorizedRoot
        case invalidDirectory
        case backupExclusionNotApplied
    }

    private let applicationSupport: URL
    private let files = FileManager.default

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport.standardizedFileURL
    }

    static func prepare(absoluteRoot: String) throws -> Bool {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PreparationError.unavailableApplicationSupport
        }
        return try ManualUploadStagingExclusion(applicationSupport: support).prepare(absoluteRoot: absoluteRoot)
    }

    func prepare(absoluteRoot: String) throws -> Bool {
        let expected = applicationSupport.appendingPathComponent("manual-upload-staging-v1", isDirectory: true)
        var requested = URL(fileURLWithPath: absoluteRoot, isDirectory: true).standardizedFileURL
        guard absoluteRoot.hasPrefix("/"), requested.path == expected.path else {
            throw PreparationError.unauthorizedRoot
        }
        if files.fileExists(atPath: requested.path) {
            let attributes = try requested.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                throw PreparationError.invalidDirectory
            }
        }
        try files.createDirectory(at: requested, withIntermediateDirectories: true)
        guard requested.resolvingSymlinksInPath().deletingLastPathComponent() == applicationSupport.resolvingSymlinksInPath() else {
            throw PreparationError.unauthorizedRoot
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try requested.setResourceValues(values)
        guard try requested.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
            throw PreparationError.backupExclusionNotApplied
        }
        return true
    }
}
