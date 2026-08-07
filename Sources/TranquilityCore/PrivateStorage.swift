import Foundation

/// Everything this app stores is private by default.
///
/// The data directory holds every session's assistant messages, every recording of
/// the user's voice, and the transcripts of both. `FileManager` creates directories
/// 0755 and most write paths create files 0644, so on a machine with more than one
/// account all of that was readable by any other local user. Two files were 0600
/// only because they were written through `open(2)` with an explicit mode — which is
/// how the inconsistency was noticed.
///
/// The directory mode is the load-bearing one: 0700 denies traversal regardless of
/// what modes individual files end up with, including files written by GRDB or
/// AVFoundation that this code never touches directly.
public enum PrivateStorage {
    /// Create a directory only the owner can enter.
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory does not apply attributes to directories that already
        // exist, so an install predating this change stays 0755 without the reset.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Restrict a file to its owner. Safe to call on something that does not exist.
    public static func protect(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Bring an existing installation up to the current expectations. Called at
    /// startup because the modes above only apply to files created after this shipped.
    public static func harden(directory: URL) {
        try? createDirectory(at: directory)
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            try? FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
    }
}
