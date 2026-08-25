import CSQLite
import Darwin
import Foundation

public enum ApplicationInstanceLockError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Media Memory 已经在运行。请使用现有窗口。"
        case let .unavailable(message):
            "无法建立 Media Memory 单实例锁：\(message)"
        }
    }
}

/// Process-scoped advisory lock held for the whole AppModel lifetime. Startup
/// recovery and filesystem GC are safe only after this exclusive lock succeeds.
public final class ApplicationInstanceLock: @unchecked Sendable {
    private var descriptor: Int32 = -1

    public init(url: URL) throws {
        let opened = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard opened >= 0 else {
            throw ApplicationInstanceLockError.unavailable(
                String(cString: strerror(errno))
            )
        }
        guard media_memory_flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(opened)
            if code == EWOULDBLOCK {
                throw ApplicationInstanceLockError.alreadyRunning
            }
            throw ApplicationInstanceLockError.unavailable(
                String(cString: strerror(code))
            )
        }
        descriptor = opened
    }

    deinit {
        if descriptor >= 0 {
            _ = media_memory_flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }
}
