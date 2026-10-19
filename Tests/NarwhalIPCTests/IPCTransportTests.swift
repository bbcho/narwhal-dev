import Darwin
import Dispatch
import Foundation
import Testing
import NarwhalCore
@testable import NarwhalIPC

@Suite("IPC transport", .serialized)
struct IPCTransportTests {
    @Test("Losing server never unlinks or disrupts the live server")
    func losingServerPreservesLiveServer() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let winner = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "winner"))
        }
        try winner.start()
        defer { winner.stop() }

        let existingClient = IPCClient(socketPath: endpoint.socketPath)
        defer { existingClient.close() }
        #expect(try existingClient.send(.status) == .ok(commandID: CommandID(raw: "winner")))

        let loser = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "loser"))
        }
        #expect(throws: IPCTransportError.self) {
            try loser.start()
        }
        loser.stop()

        #expect(FileManager.default.fileExists(atPath: endpoint.socketPath))
        #expect(try existingClient.send(.status) == .ok(commandID: CommandID(raw: "winner")))
        let newClient = IPCClient(socketPath: endpoint.socketPath)
        defer { newClient.close() }
        #expect(try newClient.send(.status) == .ok(commandID: CommandID(raw: "winner")))
    }

    @Test("Server refuses to delete a non-socket endpoint")
    func nonSocketEndpointIsPreserved() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        try Data("owned data".utf8).write(to: URL(fileURLWithPath: endpoint.socketPath))
        let server = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "unexpected"))
        }

        #expect(throws: IPCTransportError.self) {
            try server.start()
        }
        #expect(try String(contentsOfFile: endpoint.socketPath, encoding: .utf8) == "owned data")
    }

    @Test("Server lock is private and persists after shutdown")
    func serverLockPersistsPrivately() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let server = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "ok"))
        }

        try server.start()
        let lockPath = IPCDefaults.lockPath(forSocketPath: endpoint.socketPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: lockPath)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        server.stop()
        #expect(FileManager.default.fileExists(atPath: lockPath))
        #expect(!FileManager.default.fileExists(atPath: endpoint.socketPath))
    }

    @Test("Concurrent servers produce exactly one socket owner")
    func concurrentServersProduceOneOwner() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let servers = ["first", "second"].map { name in
            IPCServer(socketPath: endpoint.socketPath) { _ in
                .ok(commandID: CommandID(raw: name))
            }
        }
        let results = LockedResults()
        let group = DispatchGroup()
        for server in servers {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try server.start()
                    results.recordSuccess()
                } catch {
                    results.record(error)
                }
            }
        }
        group.wait()
        defer { servers.forEach { $0.stop() } }

        #expect(results.successCount == 1)
        #expect(results.errors.count == 1)
        let client = IPCClient(socketPath: endpoint.socketPath)
        defer { client.close() }
        let reply = try client.send(.status)
        #expect(reply == .ok(commandID: CommandID(raw: "first"))
            || reply == .ok(commandID: CommandID(raw: "second")))
    }

    @Test("Stop waits for an in-progress start and cleans published resources")
    func stopWaitsForInProgressStart() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let reachedCheckpoint = DispatchSemaphore(value: 0)
        let releaseCheckpoint = DispatchSemaphore(value: 0)
        let startFinished = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let results = LockedResults()
        let server = IPCServer(
            socketPath: endpoint.socketPath,
            beforePublishStartedResources: {
                reachedCheckpoint.signal()
                releaseCheckpoint.wait()
            },
            handle: { _ in .ok(commandID: CommandID(raw: "ok")) }
        )

        DispatchQueue.global().async {
            defer { startFinished.signal() }
            do {
                try server.start()
                results.recordSuccess()
            } catch {
                results.record(error)
            }
        }
        #expect(reachedCheckpoint.wait(timeout: .now() + 2) == .success)

        DispatchQueue.global().async {
            server.stop()
            stopFinished.signal()
        }
        #expect(stopFinished.wait(timeout: .now() + 0.05) == .timedOut)

        releaseCheckpoint.signal()
        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(stopFinished.wait(timeout: .now() + 2) == .success)
        #expect(results.successCount == 1)
        #expect(results.errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: endpoint.socketPath))
        server.stop()
    }

    @Test("Lock symlink is rejected without touching its target")
    func lockSymlinkIsRejected() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let target = endpoint.directory.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        let lockPath = IPCDefaults.lockPath(forSocketPath: endpoint.socketPath)
        try FileManager.default.createSymbolicLink(atPath: lockPath, withDestinationPath: target.path)
        let server = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "unexpected"))
        }

        #expect(throws: IPCTransportError.self) {
            try server.start()
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: endpoint.socketPath))
    }

    @Test("Current-user stale socket is reclaimed under the endpoint lock")
    func staleSocketIsReclaimed() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let staleFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard staleFD >= 0 else { throw POSIXError(.EIO) }
        try withSocketAddress(path: endpoint.socketPath) { address, length in
            guard Darwin.bind(staleFD, address, length) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        Darwin.close(staleFD)
        #expect(FileManager.default.fileExists(atPath: endpoint.socketPath))

        let server = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "reclaimed"))
        }
        try server.start()
        defer { server.stop() }
        let client = IPCClient(socketPath: endpoint.socketPath)
        defer { client.close() }
        #expect(try client.send(.status) == .ok(commandID: CommandID(raw: "reclaimed")))
    }

    @Test("Lock and stale-socket classifiers reject wrong ownership and type")
    func ownershipClassifiersRejectUnsafeMetadata() {
        let currentUID = Darwin.getuid()
        let wrongOwnerLock = IPCPathMetadata(
            kind: .regularFile,
            ownerUID: currentUID + 1,
            permissions: 0o600,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validateLockMetadata(
                path: "/private/tmp/n.lock",
                metadata: wrongOwnerLock,
                expectedUID: currentUID
            ).get()
        }

        let regularSocketCandidate = IPCPathMetadata(
            kind: .regularFile,
            ownerUID: currentUID,
            permissions: 0o600,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try reclaimableSocketIdentity(
                path: "/private/tmp/n.sock",
                metadata: regularSocketCandidate,
                expectedUID: currentUID
            ).get()
        }
    }

    @Test("Client rejects a server with the wrong peer UID")
    func clientRejectsWrongServerUID() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let server = IPCServer(socketPath: endpoint.socketPath) { _ in
            .ok(commandID: CommandID(raw: "server"))
        }
        try server.start()
        defer { server.stop() }
        let client = IPCClient(
            socketPath: endpoint.socketPath,
            peerUIDReader: { _ in .success(Darwin.getuid() + 1) }
        )

        #expect(throws: IPCTransportError.self) {
            _ = try client.send(.status)
        }

        let validClient = IPCClient(socketPath: endpoint.socketPath)
        defer { validClient.close() }
        #expect(try validClient.send(.status) == .ok(commandID: CommandID(raw: "server")))
    }

    @Test("Startup probe rejects a live listener with the wrong peer UID")
    func startupProbeRejectsWrongPeerUID() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let listener = try rawListeningSocket(path: endpoint.socketPath)
        defer { closeSocketForTest(listener) }
        let server = IPCServer(
            socketPath: endpoint.socketPath,
            peerUIDReader: { _ in .success(Darwin.getuid() + 1) },
            handle: { _ in .ok(commandID: CommandID(raw: "unexpected")) }
        )

        do {
            try server.start()
            Issue.record("Expected wrong-UID probe failure")
        } catch IPCTransportError.peerUIDMismatch(let expected, let actual) {
            #expect(expected == Darwin.getuid())
            #expect(actual == Darwin.getuid() + 1)
        } catch {
            Issue.record("Expected peerUIDMismatch, got \(String(describing: error))")
        }
        #expect(FileManager.default.fileExists(atPath: endpoint.socketPath))
    }

    @Test("Server rejects one wrong-UID client and continues accepting")
    func serverRejectsWrongUIDAndContinues() throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let peerUIDs = LockedPeerUIDSequence([
            Darwin.getuid() + 1,
            Darwin.getuid()
        ])
        let handled = LockedCounter()
        let server = IPCServer(
            socketPath: endpoint.socketPath,
            peerUIDReader: { _ in .success(peerUIDs.next()) },
            handle: { _ in
                handled.increment()
                return .ok(commandID: CommandID(raw: "accepted"))
            }
        )
        try server.start()
        defer { server.stop() }

        let rejected = IPCClient(socketPath: endpoint.socketPath)
        #expect(throws: IPCTransportError.self) {
            _ = try rejected.send(.status)
        }
        #expect(handled.value == 0)

        let accepted = IPCClient(socketPath: endpoint.socketPath)
        defer { accepted.close() }
        #expect(try accepted.send(.status) == .ok(commandID: CommandID(raw: "accepted")))
        #expect(handled.value == 1)
    }

    @Test("Production IPC path uses the private Darwin user temporary directory")
    func productionPathUsesPrivateUserDirectory() throws {
        let expectedDirectory = try darwinUserTemporaryDirectoryForTest()

        #expect(try IPCDefaults.socketPath() == expectedDirectory + "/narwhal.sock")
        #expect(IPCDefaults.lockPath(forSocketPath: expectedDirectory + "/narwhal.sock") == expectedDirectory + "/narwhal.lock")
    }

    @Test("Explicit IPC endpoints receive independent lock paths")
    func explicitEndpointsReceiveIndependentLocks() {
        #expect(IPCDefaults.lockPath(forSocketPath: "/private/tmp/first.sock") == "/private/tmp/first.lock")
        #expect(IPCDefaults.lockPath(forSocketPath: "/private/tmp/second") == "/private/tmp/second.lock")
    }

    @Test("Private runtime directory validation rejects unsafe metadata")
    func privateRuntimeDirectoryRejectsUnsafeMetadata() throws {
        let path = "/private/var/folders/example/T"
        let safe = IPCPathMetadata(
            kind: .directory,
            ownerUID: Darwin.getuid(),
            permissions: 0o700,
            device: 1,
            inode: 2
        )
        try validatePrivateRuntimeDirectory(path: path, metadata: safe, expectedUID: Darwin.getuid()).get()

        let worldAccessible = IPCPathMetadata(
            kind: .directory,
            ownerUID: Darwin.getuid(),
            permissions: 0o755,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validatePrivateRuntimeDirectory(
                path: path,
                metadata: worldAccessible,
                expectedUID: Darwin.getuid()
            ).get()
        }

        let wrongOwner = IPCPathMetadata(
            kind: .directory,
            ownerUID: Darwin.getuid() + 1,
            permissions: 0o700,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validatePrivateRuntimeDirectory(
                path: path,
                metadata: wrongOwner,
                expectedUID: Darwin.getuid()
            ).get()
        }

        let regularFile = IPCPathMetadata(
            kind: .regularFile,
            ownerUID: Darwin.getuid(),
            permissions: 0o700,
            device: 1,
            inode: 2
        )
        #expect(throws: IPCTransportError.self) {
            try validatePrivateRuntimeDirectory(
                path: path,
                metadata: regularFile,
                expectedUID: Darwin.getuid()
            ).get()
        }
    }

    @Test("Server handles multiple newline-delimited commands on one connection")
    func serverReusesConnectionForMultipleCommands() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path) { command in
            switch command {
            case .resetLayout:
                return .ok(commandID: CommandID(raw: "reset-ok"))
            case .pushFocused(.left):
                return .ok(commandID: CommandID(raw: "push-left-ok"))
            default:
                return .error(commandID: CommandID(raw: "unexpected"), code: "unexpected_command", message: "\(command)")
            }
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        let client = IPCClient(socketPath: path)
        defer { client.close() }

        let resetReply = try client.send(.resetLayout)
        let pushReply = try client.send(.pushFocused(.left))

        #expect(resetReply == .ok(commandID: CommandID(raw: "reset-ok")))
        #expect(pushReply == .ok(commandID: CommandID(raw: "push-left-ok")))

        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Server returns exact structured error for invalid command JSON")
    func invalidJSONReturnsStructuredError() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path) { _ in
            .ok(commandID: CommandID(raw: "should-not-run"))
        }
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path)
        defer { client.close() }

        let reply = try client.sendRawLine(Data(#"{"command":"push","direction":"sideways"}"#.utf8) + Data([0x0A]))

        #expect(reply == .error(
            commandID: CommandID(raw: "decode-error"),
            code: "invalid_json",
            message: "Invalid IPC command JSON"
        ))
    }

    @Test("Server stop closes idle active client sockets")
    func stopClosesIdleActiveClientSockets() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path) { _ in
            .ok(commandID: CommandID(raw: "should-not-run"))
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectRawSocket(path: path)
        defer { Darwin.close(fd) }
        try await Task.sleep(nanoseconds: 20_000_000)

        server.stop()

        var byte: UInt8 = 0
        let closed = try await waitUntil {
            let count = Darwin.read(fd, &byte, 1)
            if count == 0 { return true }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return false }
            if count < 0, errno == EINTR { return false }
            return true
        }
        #expect(closed)
    }

    @Test("Server survives client closing before reply write")
    func serverSurvivesClientClosingBeforeReplyWrite() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path) { _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .ok(commandID: CommandID(raw: "still-running"))
        }
        try server.start()
        defer { server.stop() }

        let fd = try connectRawSocket(path: path, nonBlocking: false)
        try writeAllRaw(Data(#"{"command":"resetLayout"}"#.utf8) + Data([0x0A]), to: fd)
        Darwin.close(fd)
        try await Task.sleep(nanoseconds: 50_000_000)

        let client = IPCClient(socketPath: path)
        defer { client.close() }

        #expect(try client.send(.resetLayout) == .ok(commandID: CommandID(raw: "still-running")))
    }

    @Test("Idle clients time out and release bounded server slots")
    func idleClientsReleaseServerSlotsAfterTimeout() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path, maxConnections: 2, ioTimeout: 0.08) { _ in
            .ok(commandID: CommandID(raw: "recovered"))
        }
        try server.start()
        defer { server.stop() }

        let first = try connectRawSocket(path: path)
        defer { Darwin.close(first) }
        let second = try connectRawSocket(path: path)
        defer { Darwin.close(second) }
        try await Task.sleep(nanoseconds: 180_000_000)

        let client = IPCClient(socketPath: path, ioTimeout: 0.5)
        defer { client.close() }
        #expect(try client.send(.resetLayout) == .ok(commandID: CommandID(raw: "recovered")))
    }

    @Test("Server answers while all but one cooperative thread are blocked")
    func serverAnswersWhileCooperativePoolIsNearlySaturated() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path, ioTimeout: 3) { _ in
            .ok(commandID: CommandID(raw: "served"))
        }
        try server.start()
        defer { server.stop() }
        let blockerCount = max(0, ProcessInfo.processInfo.activeProcessorCount - 1)
        let release = DispatchSemaphore(value: 0)
        let releaseBlockers = { for _ in 0..<blockerCount { release.signal() } }
        defer { releaseBlockers() }
        // Without this watchdog a regression deadlocks the whole test process
        // instead of failing: the test itself needs a pool thread to resume.
        Thread.detachNewThread {
            sleep(5)
            releaseBlockers()
        }
        for _ in 0..<blockerCount {
            Task.detached { blockCooperativeThread(on: release) }
        }

        let reply = try await sendOnDedicatedThread(.resetLayout, path: path, ioTimeout: 3)

        #expect(reply == .ok(commandID: CommandID(raw: "served")))
    }

    @Test("A client trickling bytes cannot hold a server slot past the I/O deadline")
    func tricklingClientReleasesSlotAtDeadline() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path, maxConnections: 1, ioTimeout: 0.3) { _ in
            .ok(commandID: CommandID(raw: "after-trickle"))
        }
        try server.start()
        defer { server.stop() }
        let trickler = try connectRawSocket(path: path, nonBlocking: false)
        defer { Darwin.close(trickler) }
        try configureNoSIGPIPE(trickler)
        let stopTrickling = LockedCounter()
        defer { stopTrickling.increment() }
        Thread.detachNewThread {
            var byte = UInt8(ascii: "{")
            while stopTrickling.value == 0, Darwin.write(trickler, &byte, 1) == 1 {
                usleep(100_000)
            }
        }

        let reply = try await sendOnDedicatedThread(
            .resetLayout,
            path: path,
            ioTimeout: 1,
            retryingUntil: Date().addingTimeInterval(2.5)
        )

        #expect(reply == .ok(commandID: CommandID(raw: "after-trickle")))
    }

    @Test("Client abandons a connection when its reply deadline expires")
    func clientAbandonsConnectionAfterReplyTimeout() async throws {
        let endpoint = try temporaryEndpoint()
        defer { endpoint.cleanup() }
        let path = endpoint.socketPath
        let server = IPCServer(socketPath: path, ioTimeout: 1.0) { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .ok(commandID: CommandID(raw: "late"))
        }
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketPath: path, ioTimeout: 0.05)
        do {
            _ = try client.send(.resetLayout)
            Issue.record("Expected client read timeout")
        } catch IPCTransportError.timedOut(let operation) {
            #expect(operation == "read")
        } catch {
            Issue.record("Expected IPC read timeout, got \(String(describing: error))")
        }
    }

    private struct TestEndpoint {
        let directory: URL
        let socketPath: String

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private final class LockedResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storedSuccessCount = 0
        private var storedErrors: [Error] = []

        var successCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedSuccessCount
        }

        var errors: [Error] {
            lock.lock()
            defer { lock.unlock() }
            return storedErrors
        }

        func recordSuccess() {
            lock.lock()
            storedSuccessCount += 1
            lock.unlock()
        }

        func record(_ error: Error) {
            lock.lock()
            storedErrors.append(error)
            lock.unlock()
        }
    }

    private final class LockedPeerUIDSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [uid_t]

        init(_ values: [uid_t]) {
            self.values = values
        }

        func next() -> uid_t {
            lock.lock()
            defer { lock.unlock() }
            return values.isEmpty ? Darwin.getuid() : values.removeFirst()
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }

        func increment() {
            lock.lock()
            storedValue += 1
            lock.unlock()
        }
    }

    /// Runs the blocking client off the cooperative pool so the test never
    /// competes with the server for pool threads.
    private func sendOnDedicatedThread(
        _ command: IPCCommandDTO,
        path: String,
        ioTimeout: TimeInterval,
        retryingUntil deadline: Date? = nil
    ) async throws -> IPCReplyDTO {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                while true {
                    do {
                        let reply = try IPCClient(socketPath: path, ioTimeout: ioTimeout).send(command)
                        continuation.resume(returning: reply)
                        return
                    } catch {
                        guard let deadline, Date() < deadline else {
                            continuation.resume(throwing: error)
                            return
                        }
                        usleep(50_000)
                    }
                }
            }
        }
    }

    private func temporaryEndpoint() throws -> TestEndpoint {
        let token = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/private/tmp/ni-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return TestEndpoint(
            directory: directory,
            socketPath: directory.appendingPathComponent("n.sock").path
        )
    }

    private func darwinUserTemporaryDirectoryForTest() throws -> String {
        let required = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard required > 1 else { throw POSIXError(.EIO) }
        var buffer = [CChar](repeating: 0, count: required)
        guard Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, required) == required else {
            throw POSIXError(.EIO)
        }
        return String(cString: buffer).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty
            ? "/"
            : "/" + String(cString: buffer)
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
    }

    private func connectRawSocket(path: String, nonBlocking: Bool = true) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try configureNoSIGPIPE(fd)
            try withSocketAddress(path: path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            if nonBlocking {
                let flags = Darwin.fcntl(fd, F_GETFL, 0)
                guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func rawListeningSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        do {
            try withSocketAddress(path: path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            guard Darwin.listen(fd, 1) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func closeSocketForTest(_ fd: Int32) {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func configureNoSIGPIPE(_ fd: Int32) throws {
        var noSIGPIPE: Int32 = 1
        guard Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSIGPIPE,
            socklen_t(MemoryLayout.size(ofValue: noSIGPIPE))
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writeAllRaw(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 {
                    throw POSIXError(.EPIPE)
                }
                written += count
            }
        }
    }

    private func withSocketAddress<Result>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) throws -> Result {
        let pathBytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= pathCapacity else {
            throw POSIXError(.ENAMETOOLONG)
        }
        guard let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) else {
            throw POSIXError(.EINVAL)
        }
        withUnsafeMutableBytes(of: &address) { rawAddress in
            for (index, byte) in pathBytes.enumerated() {
                rawAddress[pathOffset + index] = byte
            }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, length)
            }
        }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        for _ in 0..<50 {
            if try condition() {
                return true
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return try condition()
    }
}

/// Deliberately occupies the calling cooperative pool thread until `semaphore` signals.
private func blockCooperativeThread(on semaphore: DispatchSemaphore) {
    semaphore.wait()
}
