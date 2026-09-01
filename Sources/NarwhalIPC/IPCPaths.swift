import Darwin
import Foundation

enum IPCPathKind: Equatable, Sendable {
    case directory
    case regularFile
    case socket
    case symbolicLink
    case other
}

struct IPCPathMetadata: Equatable, Sendable {
    let kind: IPCPathKind
    let ownerUID: uid_t
    let permissions: mode_t
    let device: UInt64
    let inode: UInt64
}

public enum IPCDefaults {
    public static func socketPath() throws -> String {
        let required = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard required > 1 else {
            throw IPCTransportError.runtimeDirectoryUnavailable(errno: errno)
        }
        var buffer = [CChar](repeating: 0, count: Int(required))
        let written = buffer.withUnsafeMutableBufferPointer { pointer in
            Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, pointer.baseAddress, required)
        }
        guard written == required else {
            throw IPCTransportError.runtimeDirectoryUnavailable(errno: errno)
        }

        let directory = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .standardizedFileURL.path
        let metadata = try ipcPathMetadata(at: directory)
        try validatePrivateRuntimeDirectory(
            path: directory,
            metadata: metadata,
            expectedUID: Darwin.getuid()
        ).get()
        return URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("narwhal.sock", isDirectory: false)
            .path
    }

    public static func lockPath(forSocketPath socketPath: String) -> String {
        let url = URL(fileURLWithPath: socketPath)
        if url.pathExtension == "sock" {
            return url.deletingPathExtension().appendingPathExtension("lock").path
        }
        return socketPath + ".lock"
    }
}

func validatePrivateRuntimeDirectory(
    path: String,
    metadata: IPCPathMetadata,
    expectedUID: uid_t
) -> Result<Void, IPCTransportError> {
    guard metadata.kind == .directory,
          metadata.ownerUID == expectedUID,
          metadata.permissions & 0o077 == 0
    else {
        return .failure(.unsafeRuntimeDirectory(path: path))
    }
    return .success(())
}

func ipcPathMetadata(at path: String) throws -> IPCPathMetadata {
    var value = stat()
    guard Darwin.lstat(path, &value) == 0 else {
        throw IPCTransportError.pathMetadataFailed(path: path, errno: errno)
    }
    let fileType = value.st_mode & S_IFMT
    let kind: IPCPathKind
    switch fileType {
    case S_IFDIR:
        kind = .directory
    case S_IFREG:
        kind = .regularFile
    case S_IFSOCK:
        kind = .socket
    case S_IFLNK:
        kind = .symbolicLink
    default:
        kind = .other
    }
    return IPCPathMetadata(
        kind: kind,
        ownerUID: value.st_uid,
        permissions: value.st_mode & 0o777,
        device: UInt64(value.st_dev),
        inode: UInt64(value.st_ino)
    )
}
