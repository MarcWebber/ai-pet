import Darwin
import Foundation
import JellyCore

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
}

public protocol ProcessRunning: AnyObject {
    func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        timeout: TimeInterval
    ) async throws -> ProcessResult
    func cancel()
}

public final class FoundationProcessRunner: ProcessRunning {
    private let lock = NSLock()
    private let currentDirectoryURL: URL?
    private var active: [ObjectIdentifier: Process] = [:]

    public init(currentDirectoryURL: URL? = nil) {
        self.currentDirectoryURL = currentDirectoryURL
    }

    public func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = environment(executableURL)
        process.currentDirectoryURL = currentDirectoryURL
        lock.withLock { active[ObjectIdentifier(process)] = process }
        defer { _ = lock.withLock { active.removeValue(forKey: ObjectIdentifier(process)) } }

        return try await withTaskCancellationHandler {
            let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            do {
                let status = try await wait(
                    for: process, input: input,
                    data: standardInput, timeout: timeout
                )
                let data = await stdout.value
                let errorData = await stderr.value
                return ProcessResult(
                    exitCode: status,
                    stdout: data,
                    stderr: errorData
                )
            } catch {
                terminate(process)
                _ = await stdout.value; _ = await stderr.value
                throw error
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        lock.withLock { Array(active.values) }.forEach(terminate)
    }

    private func wait(
        for process: Process,
        input: Pipe,
        data: Data,
        timeout: TimeInterval
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = {
                        continuation.resume(returning: $0.terminationStatus)
                    }
                    do {
                        try process.run()
                        input.fileHandleForWriting.write(data)
                        try? input.fileHandleForWriting.close()
                    } catch {
                        process.terminationHandler = nil
                        try? input.fileHandleForWriting.close()
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                )
                throw PetFailure.screenActionFailed
            }
            defer { group.cancelAll() }
            do { return try await group.next() ?? { throw PetFailure.invalidCodexOutput }() }
            catch { terminate(process); throw error }
        }
    }

    private func environment(_ executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = executable.deletingLastPathComponent().standardizedFileURL.path
        var path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        path.removeAll { $0 == directory }; path.insert(directory, at: 0)
        environment["PATH"] = path.joined(separator: ":")
        return environment
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.25)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
