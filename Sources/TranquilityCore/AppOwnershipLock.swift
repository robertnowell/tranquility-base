import Darwin
import Foundation

/// One owner of the global hotkey, microphone, and live Application Support.
///
/// LaunchServices can find another instance only by bundle identifier. Prod
/// and Dev intentionally have different identifiers, so a filesystem lock in
/// their shared data directory is the identity-neutral arbiter. The descriptor
/// stays open for this object's lifetime; the kernel releases it on a crash.
public final class AppOwnershipLock: @unchecked Sendable {
    public enum AcquireError: Error, Equatable, CustomStringConvertible {
        case alreadyHeld(String?)
        case cannotOpen(Int32)
        case cannotLock(Int32)

        public var description: String {
            switch self {
            case .alreadyHeld(let owner):
                return owner.map { "already held by \($0)" } ?? "already held"
            case .cannotOpen(let code): return "could not open ownership file (errno \(code))"
            case .cannotLock(let code): return "could not lock ownership file (errno \(code))"
            }
        }
    }

    public static let filename = "app-owner.lock"
    public let url: URL
    private let descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    public static func acquire(
        in directory: URL,
        owner: String,
        pid: Int32 = getpid()
    ) throws -> AppOwnershipLock {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(filename)
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AcquireError.cannotOpen(errno) }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            let note = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Darwin.close(fd)
            if code == EWOULDBLOCK {
                throw AcquireError.alreadyHeld(note?.isEmpty == false ? note : nil)
            }
            throw AcquireError.cannotLock(code)
        }

        let note = "\(owner) pid=\(pid)"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        note.withCString { pointer in
            _ = Darwin.write(fd, pointer, strlen(pointer))
        }
        fsync(fd)
        return AppOwnershipLock(url: url, descriptor: fd)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
