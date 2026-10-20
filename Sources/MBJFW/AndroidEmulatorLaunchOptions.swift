import Foundation
import Darwin

enum AndroidEmulatorLaunchOptions {
    // Preserve the launch feature set used by the working native-window path.
    static let features = "Vulkan,GuestAngle,VirtioInput,VirtioMouse,VirtioDualModeMouse,HWCMultiConfigs,-SupportPixelFold,-DeviceSkinOverlay"
    static let displayArguments = ["-qt-hide-window"]
}

enum AndroidBootReadiness {
    static func isReady(bootCompleted: String?, activityService: String?, packageService: String?) -> Bool {
        let booted = bootCompleted?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let activityReady = activityService?.contains("Service activity: found") == true
        let packageReady = packageService?.contains("Service package: found") == true
        return booted && activityReady && packageReady
    }
}

/// Leases emulator console ports both inside this process and across multiple
/// MBJFW launches. The file lock is released by the kernel if MBJFW crashes.
@MainActor
final class EmulatorPortLease {
    let port: Int

    private static var leasedPorts = Set<Int>()
    private var descriptor: Int32?

    private init(port: Int, descriptor: Int32) {
        self.port = port
        self.descriptor = descriptor
        Self.leasedPorts.insert(port)
    }

    static func reserve(in root: URL, adbDevices: String) throws -> EmulatorPortLease {
        let usedPorts = Set(adbDevices.split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            guard line.hasPrefix("emulator-") else { return nil }
            return Int(line.dropFirst("emulator-".count).prefix(4))
        })
        let lockDirectory = root.appending(path: "emulator-port-locks")
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)

        for port in stride(from: 5580, through: 5680, by: 2) {
            guard !usedPorts.contains(port), !leasedPorts.contains(port) else { continue }
            let lockPath = lockDirectory.appending(path: "emulator-\(port).lock").path
            let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                continue
            }
            return EmulatorPortLease(port: port, descriptor: descriptor)
        }
        throw AndroidEmulatorError.emulatorSlotsExhausted
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        Self.leasedPorts.remove(port)
    }
}

struct EmulatorAudioConfiguration: Equatable {
    let arguments: [String]
    let environment: [String: String]

    init(settings: ProfileSettings) {
        let outputEnabled = !settings.disableGameAudio
        let inputEnabled = settings.hostMicrophoneEnabled

        if !outputEnabled && !inputEnabled {
            arguments = ["-no-audio"]
            environment = ["QEMU_AUDIO_OUT_DRV": "none", "QEMU_AUDIO_IN_DRV": "none"]
            return
        }

        var arguments: [String] = []
        if inputEnabled { arguments.append("-allow-host-audio") }
        self.arguments = arguments
        environment = [
            "QEMU_AUDIO_OUT_DRV": outputEnabled ? "coreaudio" : "none",
            "QEMU_AUDIO_IN_DRV": inputEnabled ? "coreaudio" : "none"
        ]
    }
}

@MainActor
final class EmulatorBootGate {
    static let shared = EmulatorBootGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []

    func acquire() async throws -> Bool {
        try Task.checkCancellation()
        guard isHeld else {
            isHeld = true
            return false
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
