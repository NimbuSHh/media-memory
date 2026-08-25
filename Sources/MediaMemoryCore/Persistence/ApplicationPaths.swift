import Foundation

public enum ApplicationPaths {
    public static func baseDirectoryURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appending(path: "MediaMemory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func databaseURL() throws -> URL {
        try baseDirectoryURL()
            .appending(path: "media-memory.sqlite", directoryHint: .notDirectory)
    }

    public static func workDirectoryURL() throws -> URL {
        let directory = try baseDirectoryURL()
            .appending(path: "Work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func modelConfigurationURL() throws -> URL {
        try baseDirectoryURL()
            .appending(path: "models.json", directoryHint: .notDirectory)
    }

    public static func instanceLockURL() throws -> URL {
        try baseDirectoryURL()
            .appending(path: "instance.lock", directoryHint: .notDirectory)
    }

    public static func cleanupAbandonedRuns(in workRoot: URL) throws {
        let root = workRoot.standardizedFileURL
            .appending(path: "Runs", directoryHint: .isDirectory)
        guard try isOrdinaryDirectory(root) else { return }
        for directory in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) where isJobIdentifier(directory.lastPathComponent) {
            guard try isOrdinaryDirectory(directory),
                  !containsSymbolicLink(in: directory) else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Prefetch inputs are scratch data and are never referenced by committed
    /// database rows. This is called only after the process-wide instance lock
    /// succeeds, so every validated job directory is necessarily abandoned.
    public static func cleanupAbandonedPrefetch(in workRoot: URL) throws {
        let root = workRoot.standardizedFileURL
            .appending(path: "Prefetch", directoryHint: .isDirectory)
        guard try isOrdinaryDirectory(root) else { return }
        for directory in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) where isJobIdentifier(directory.lastPathComponent) {
            guard try isOrdinaryDirectory(directory),
                  !containsSymbolicLink(in: directory) else { continue }
            try FileManager.default.removeItem(at: directory)
        }
    }

    public static func cleanupUnreferencedFrames(
        in workRoot: URL,
        referencedRelativePaths: Set<String>
    ) throws {
        let root = workRoot.standardizedFileURL
            .appending(path: "Frames", directoryHint: .isDirectory)
        guard try isOrdinaryDirectory(root) else { return }
        let jobs = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for job in jobs where isJobIdentifier(job.lastPathComponent) {
            guard try isOrdinaryDirectory(job) else { continue }
            let attempts = try FileManager.default.contentsOfDirectory(
                at: job,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for attempt in attempts where Int(attempt.lastPathComponent) != nil {
                guard try isOrdinaryDirectory(attempt) else { continue }
                let relativeDirectory = "Frames/\(job.lastPathComponent)/\(attempt.lastPathComponent)/"
                let isReferenced = referencedRelativePaths.contains {
                    $0.hasPrefix(relativeDirectory)
                }
                guard !isReferenced, !containsSymbolicLink(in: attempt) else { continue }
                try FileManager.default.removeItem(at: attempt)
            }
        }
    }

    private static func isOrdinaryDirectory(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func containsSymbolicLink(in directory: URL) -> Bool {
        var encounteredError = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in
                encounteredError = true
                return false
            }
        ) else { return true }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
                return true
            }
            if values.isSymbolicLink == true { return true }
        }
        return encounteredError
    }

    private static func isJobIdentifier(_ value: String) -> Bool {
        guard value.utf8.count == 32 else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
