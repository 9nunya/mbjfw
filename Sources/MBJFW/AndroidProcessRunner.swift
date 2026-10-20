import Foundation
import Darwin

@MainActor
enum AndroidProcessRunner {
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        logURL: URL,
        input: String? = nil,
        timeout: Duration? = nil,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let descriptor = open(logURL.path, O_WRONLY | O_APPEND)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let logHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let invocation = ([executable.lastPathComponent] + arguments)
            .map(Self.shellQuote)
            .joined(separator: " ")
        try logHandle.write(contentsOf: Data("\n$ \(invocation)\n".utf8))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment.merge(environment) { _, newValue in newValue }
        process.environment = processEnvironment
        let outputPipe = Pipe()
        let capture = ProcessOutputCapture(log: logHandle, progress: progress)
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            capture.consume(data)
        }
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try inputPipe.fileHandleForWriting.close()
        }
        var processTimedOut = false
        var timeoutTask: Task<Void, Never>?
        let exitStatus: Int32
        do {
            exitStatus = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    if Task.isCancelled { throw CancellationError() }
                    try process.run()
                    if let timeout {
                        timeoutTask = Task { @MainActor in
                            try? await Task.sleep(for: timeout)
                            guard !Task.isCancelled, process.isRunning else { return }
                            processTimedOut = true
                            let identifier = process.processIdentifier
                            process.terminate()
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, process.isRunning,
                                  process.processIdentifier == identifier else { return }
                            kill(identifier, SIGKILL)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
                }
            } onCancel: {
                guard process.isRunning else { return }
                let identifier = process.processIdentifier
                process.terminate()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard process.isRunning, process.processIdentifier == identifier else { return }
                    kill(identifier, SIGKILL)
                }
            }
        } catch {
            timeoutTask?.cancel()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle.close()
            throw error
        }
        timeoutTask?.cancel()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        capture.consume(outputPipe.fileHandleForReading.readDataToEndOfFile())
        try logHandle.close()
        let output = capture.output
        try Task.checkCancellation()
        if processTimedOut {
            throw AndroidCommandTimedOut(command: invocation, timeout: timeout ?? .zero)
        }
        guard exitStatus == 0 else {
            throw AndroidCommandError(command: invocation, status: exitStatus, output: output)
        }
        return output
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

struct AndroidCommandTimedOut: LocalizedError {
    let command: String
    let timeout: Duration

    var errorDescription: String? {
        "\(command) did not finish within \(Int(timeout.components.seconds)) seconds."
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let log: FileHandle
    private let progress: (@MainActor @Sendable (String) -> Void)?
    private var tail = ""
    private var bytes = Data()
    private var lastUpdate = ContinuousClock.now

    init(log: FileHandle, progress: (@MainActor @Sendable (String) -> Void)?) {
        self.log = log
        self.progress = progress
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        bytes.append(data)
        do { try log.write(contentsOf: data) } catch { }
        tail.append(String(decoding: data, as: UTF8.self))
        if tail.utf8.count > 32_768 { tail = String(tail.suffix(16_384)) }
        let text = tail
        let shouldPublish = lastUpdate.duration(to: .now) >= .milliseconds(250)
        if shouldPublish { lastUpdate = .now }
        lock.unlock()
        guard shouldPublish, let progress else { return }
        let latest = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? text
        guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in progress(String(latest.suffix(240))) }
    }
}

struct AndroidCommandError: LocalizedError {
    let command: String
    let status: Int32
    let output: String

    var errorDescription: String? {
        let details = output.split(separator: "\n").suffix(12).joined(separator: "\n")
        return "\(command) failed (exit \(status)). \(details)"
    }
}
